defmodule Mnemosyne.Session do
  @moduledoc """
  GenStateMachine managing the lifecycle of a memory session.

  States: `:idle`, `:collecting`, `:extracting`, `:failed`, `:ready`.

  Extraction is spawned under a Task.Supervisor via `async_nolink`,
  keeping the session responsive while LLM work happens in the background.
  Failed state preserves the closed episode for retry.
  """
  use GenStateMachine, callback_mode: :state_functions

  require Logger

  alias Mnemosyne.Errors.Framework.SessionError
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.MemoryStore
  alias Mnemosyne.Notifier
  alias Mnemosyne.Pipeline.Episode
  alias Mnemosyne.Pipeline.Structuring

  @type state :: :idle | :collecting | :extracting | :ready | :failed
  @type append_caller :: {:reply, GenServer.from()} | {:callback, (append_result() -> any())}
  @type append_result :: :ok | {:error, Mnemosyne.Errors.error()}

  @type t :: %__MODULE__{
          id: String.t() | nil,
          repo_id: String.t() | nil,
          registry: module() | nil,
          episode: Episode.t() | nil,
          changeset: Changeset.t() | nil,
          config: Mnemosyne.Config.t() | nil,
          llm: module() | nil,
          embedding: module() | nil,
          notifier: module() | nil,
          memory_store: GenServer.server() | nil,
          task_supervisor: module() | nil,
          extraction_task: reference() | nil,
          append_task: reference() | nil,
          append_caller: append_caller() | nil,
          append_queue: :queue.queue(),
          prev_trajectory_id: String.t() | nil,
          flush_timer: reference() | nil,
          session_timer: reference() | nil,
          trajectory_tasks: %{reference() => String.t()},
          committed_trajectory_ids: MapSet.t(String.t()),
          flush_triggered: %{String.t() => true},
          stopping: boolean()
        }

  defstruct [
    :id,
    :repo_id,
    :registry,
    :episode,
    :changeset,
    :config,
    :llm,
    :embedding,
    :notifier,
    :memory_store,
    :task_supervisor,
    :extraction_task,
    :append_task,
    :append_caller,
    :prev_trajectory_id,
    :flush_timer,
    :session_timer,
    append_queue: :queue.new(),
    trajectory_tasks: %{},
    committed_trajectory_ids: MapSet.new(),
    flush_triggered: %{},
    stopping: false
  ]

  # -- Client API --

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    registry = Keyword.fetch!(opts, :registry)
    id = generate_id()
    name = {:via, Registry, {registry, id}}
    GenStateMachine.start_link(__MODULE__, Keyword.put(opts, :id, id), name: name)
  end

  @doc """
  Opens a new episode with the given goal, transitioning from `:idle` to `:collecting`.
  """
  @spec start_episode(GenServer.server(), String.t()) :: :ok | {:error, SessionError.t()}
  def start_episode(server, goal) do
    GenStateMachine.call(server, {:start_episode, goal})
  end

  @doc """
  Appends an observation-action pair to the current episode.
  Blocks until the append completes or the timeout expires.
  """
  @spec append(GenServer.server(), String.t(), String.t()) ::
          :ok | {:error, Mnemosyne.Errors.error()}
  def append(server, observation, action) do
    GenStateMachine.call(server, {:append, observation, action}, :timer.seconds(60))
  end

  @doc """
  Like `append/3` but returns immediately. Accepts an optional callback that
  receives `:ok` or `{:error, reason}` when the append finishes.
  """
  @spec append_async(GenServer.server(), String.t(), String.t(), (append_result() -> any()) | nil) ::
          :ok
  def append_async(server, observation, action, callback \\ nil) do
    GenStateMachine.cast(server, {:append_async, observation, action, callback})
  end

  @doc """
  Closes the current episode and starts asynchronous extraction.
  """
  @spec close(GenServer.server()) :: :ok | {:error, Mnemosyne.Errors.error()}
  def close(server) do
    GenStateMachine.call(server, :close)
  end

  @doc """
  Commits the session result. In `:ready` state, applies the extracted changeset
  to the MemoryStore and transitions to `:idle`. In `:failed` state, retries
  the extraction by re-spawning the extraction task.
  """
  @spec commit(GenServer.server()) :: :ok | {:error, Mnemosyne.Errors.error()}
  def commit(server) do
    GenStateMachine.call(server, :commit)
  end

  @doc """
  Discards the extraction result and returns to `:idle`.
  """
  @spec discard(GenServer.server()) :: :ok | {:error, SessionError.t()}
  def discard(server) do
    GenStateMachine.call(server, :discard)
  end

  @doc """
  Returns the current state atom (`:idle`, `:collecting`, `:extracting`, `:ready`, `:failed`).
  """
  @spec state(GenServer.server()) :: state()
  def state(server) do
    GenStateMachine.call(server, :get_state)
  end

  @doc """
  Returns the unique session ID.
  """
  @spec id(GenServer.server()) :: String.t()
  def id(server) do
    GenStateMachine.call(server, :get_id)
  end

  @doc """
  Returns session context for use by MemoryStore.recall_in_context.

  Accepts a pid/name for direct calls, or a string session_id looked up
  via `Mnemosyne.Registry` (the default production registry).
  Returns `{:ok, %{goal: ..., recent_steps: [...]}}` or `{:ok, nil}` when idle.
  """
  @spec get_context(GenServer.server() | String.t()) :: {:ok, map() | nil}
  def get_context(server) when is_pid(server) or is_atom(server) or is_tuple(server) do
    GenStateMachine.call(server, :get_context)
  end

  def get_context(session_id) when is_binary(session_id) do
    get_context(session_id, Mnemosyne.Registry)
  end

  @doc """
  Like `get_context/1` but looks up the session in the given registry.
  """
  @spec get_context(String.t(), atom()) :: {:ok, map() | nil}
  def get_context(session_id, registry) when is_binary(session_id) do
    case Registry.lookup(registry, session_id) do
      [{pid, nil}] -> GenStateMachine.call(pid, :get_context)
      [] -> {:ok, nil}
    end
  rescue
    ArgumentError -> {:ok, nil}
  end

  # -- Callbacks --

  @impl true
  def init(opts) do
    data = %__MODULE__{
      id: Keyword.fetch!(opts, :id),
      repo_id: Keyword.get(opts, :repo_id),
      registry: Keyword.fetch!(opts, :registry),
      config: Keyword.fetch!(opts, :config),
      llm: Keyword.fetch!(opts, :llm),
      embedding: Keyword.fetch!(opts, :embedding),
      notifier: Keyword.get(opts, :notifier, Mnemosyne.Notifier.Noop),
      memory_store: Keyword.fetch!(opts, :memory_store),
      task_supervisor: Keyword.fetch!(opts, :task_supervisor)
    }

    {:ok, :idle, data}
  end

  # -- Idle State --

  @doc false
  def idle({:call, from}, {:start_episode, goal}, data) do
    episode = Episode.new(goal)
    emit_transition(data, :idle, :collecting)
    data = %{data | episode: episode}
    {:next_state, :collecting, start_timers(data), [{:reply, from, :ok}]}
  end

  def idle({:call, from}, :get_state, _data), do: {:keep_state_and_data, [{:reply, from, :idle}]}
  def idle({:call, from}, :get_id, data), do: {:keep_state_and_data, [{:reply, from, data.id}]}

  def idle({:call, from}, :get_context, _data),
    do: {:keep_state_and_data, [{:reply, from, {:ok, nil}}]}

  def idle({:call, from}, :commit, _data),
    do:
      {:keep_state_and_data,
       [{:reply, from, {:error, SessionError.exception(reason: :not_ready)}}]}

  def idle({:call, from}, :discard, _data),
    do:
      {:keep_state_and_data,
       [{:reply, from, {:error, SessionError.exception(reason: :not_discardable)}}]}

  def idle({:call, from}, {:append, _, _}, _data),
    do:
      {:keep_state_and_data,
       [{:reply, from, {:error, SessionError.exception(reason: :not_collecting)}}]}

  def idle({:call, from}, :close, _data),
    do:
      {:keep_state_and_data,
       [{:reply, from, {:error, SessionError.exception(reason: :not_collecting)}}]}

  def idle({:call, from}, _request, _data),
    do:
      {:keep_state_and_data,
       [{:reply, from, {:error, SessionError.exception(reason: :invalid_operation)}}]}

  # -- Collecting State --

  @doc false
  def collecting({:call, from}, {:append, observation, action}, data) do
    Logger.debug(
      "session #{data.id} sync append received, task=#{inspect(data.append_task)}, queue_size=#{:queue.len(data.append_queue)}"
    )

    enqueue_or_dispatch_append(data, observation, action, {:reply, from})
  end

  def collecting(:cast, {:append_async, observation, action, callback}, data) do
    Logger.debug(
      "session #{data.id} async append received, task=#{inspect(data.append_task)}, queue_size=#{:queue.len(data.append_queue)}"
    )

    caller = if callback, do: {:callback, callback}, else: nil
    enqueue_or_dispatch_append(data, observation, action, caller)
  end

  def collecting({:call, from}, :close, data) do
    Logger.debug(
      "session #{data.id} close requested, task=#{inspect(data.append_task)}, queue_size=#{:queue.len(data.append_queue)}"
    )

    cond do
      data.append_task != nil ->
        Logger.warning(
          "session #{data.id} close rejected: append task #{inspect(data.append_task)} still running"
        )

        {:keep_state_and_data,
         [{:reply, from, {:error, SessionError.exception(reason: :append_in_progress)}}]}

      map_size(data.trajectory_tasks) > 0 ->
        {:keep_state_and_data,
         [{:reply, from, {:error, SessionError.exception(reason: :extraction_in_progress)}}]}

      true ->
        handle_close(data, from)
    end
  end

  def collecting({:call, from}, {:start_episode, _}, _data),
    do:
      {:keep_state_and_data,
       [{:reply, from, {:error, SessionError.exception(reason: :not_idle)}}]}

  def collecting({:call, from}, :get_state, _data),
    do: {:keep_state_and_data, [{:reply, from, :collecting}]}

  def collecting({:call, from}, :get_id, data),
    do: {:keep_state_and_data, [{:reply, from, data.id}]}

  def collecting({:call, from}, :commit, _data),
    do:
      {:keep_state_and_data,
       [{:reply, from, {:error, SessionError.exception(reason: :not_ready)}}]}

  def collecting({:call, from}, :discard, _data),
    do:
      {:keep_state_and_data,
       [{:reply, from, {:error, SessionError.exception(reason: :not_discardable)}}]}

  def collecting({:call, from}, :get_context, data) do
    {:keep_state_and_data, [{:reply, from, build_context(data)}]}
  end

  def collecting(:info, {ref, {:ok, episode, trace}}, %{append_task: ref} = data) do
    Logger.debug(
      "session #{data.id} append task completed ok, queue_size=#{:queue.len(data.append_queue)}"
    )

    Process.demonitor(ref, [:flush])
    notify_append_caller(data.append_caller, :ok)

    prev_traj_id = data.prev_trajectory_id
    new_traj_id = episode.current_trajectory_id

    data = %{
      data
      | episode: episode,
        append_task: nil,
        append_caller: nil,
        prev_trajectory_id: nil
    }

    step = List.last(episode.steps)
    boundary_detected = prev_traj_id != nil and prev_traj_id != new_traj_id

    Notifier.safe_notify(
      data.notifier,
      data.repo_id,
      {:step_appended, data.id,
       %{
         step_index: step.index,
         trajectory_id: step.trajectory_id,
         boundary_detected: boundary_detected
       }, %{trace: trace}}
    )

    data =
      if auto_commit_enabled?(data) and boundary_detected do
        maybe_spawn_trajectory_extraction(data, prev_traj_id)
      else
        data
      end

    data = reset_timers(data)
    {:keep_state, dispatch_append(data)}
  end

  def collecting(:info, {ref, {:error, _} = error}, %{append_task: ref} = data) do
    Logger.debug(
      "session #{data.id} append task failed: #{inspect(error)}, queue_size=#{:queue.len(data.append_queue)}"
    )

    Process.demonitor(ref, [:flush])
    notify_append_caller(data.append_caller, error)
    data = %{data | append_task: nil, append_caller: nil}
    {:keep_state, dispatch_append(data)}
  end

  def collecting(:info, {:DOWN, ref, :process, _pid, reason}, %{append_task: ref} = data) do
    Logger.error(
      "session #{data.id} append task crashed: #{inspect(reason)}, queue_size=#{:queue.len(data.append_queue)}"
    )

    error = {:error, SessionError.exception(reason: :append_crashed)}
    notify_append_caller(data.append_caller, error)
    data = %{data | append_task: nil, append_caller: nil}
    {:keep_state, dispatch_append(data)}
  end

  def collecting(:info, {ref, {:ok, %Changeset{} = cs, trace}}, data)
      when is_map_key(data.trajectory_tasks, ref) do
    Process.demonitor(ref, [:flush])
    traj_id = data.trajectory_tasks[ref]

    MemoryStore.apply_changeset(data.memory_store, cs)

    metadata = %{trace: trace}

    event =
      if Map.has_key?(data.flush_triggered, traj_id) do
        {:trajectory_flushed, data.id, traj_id, %{node_count: length(cs.additions)}, metadata}
      else
        {:trajectory_committed, data.id, traj_id, %{node_count: length(cs.additions)}, metadata}
      end

    Notifier.safe_notify(data.notifier, data.repo_id, event)

    trajectory_tasks = Map.delete(data.trajectory_tasks, ref)
    committed = MapSet.put(data.committed_trajectory_ids, traj_id)
    flush_triggered = Map.delete(data.flush_triggered, traj_id)

    data = %{
      data
      | trajectory_tasks: trajectory_tasks,
        committed_trajectory_ids: committed,
        flush_triggered: flush_triggered
    }

    if data.stopping and map_size(data.trajectory_tasks) == 0 do
      Notifier.safe_notify(data.notifier, data.repo_id, {:session_expired, data.id, %{}})
      {:stop, :normal, data}
    else
      {:keep_state, data}
    end
  end

  def collecting(:info, {ref, {:error, reason}}, data)
      when is_map_key(data.trajectory_tasks, ref) do
    Process.demonitor(ref, [:flush])
    handle_trajectory_extraction_failure(data, ref, reason)
  end

  def collecting(:info, {:DOWN, ref, :process, _pid, reason}, data)
      when is_map_key(data.trajectory_tasks, ref) do
    handle_trajectory_extraction_failure(data, ref, reason)
  end

  def collecting(:info, :flush_timeout, data) do
    if data.append_task != nil or map_size(data.trajectory_tasks) > 0 do
      flush_ref = schedule_timer(:flush_timeout, data.config.session.flush_timeout_ms)
      {:keep_state, %{data | flush_timer: flush_ref}}
    else
      {:keep_state, flush_current_trajectory(data)}
    end
  end

  def collecting(:info, :session_timeout, data) do
    if data.append_task != nil or map_size(data.trajectory_tasks) > 0 do
      session_ref = schedule_timer(:session_timeout, 1_000)
      {:keep_state, %{data | session_timer: session_ref}}
    else
      case uncommitted_current_steps(data) do
        [] ->
          Notifier.safe_notify(data.notifier, data.repo_id, {:session_expired, data.id, %{}})
          {:stop, :normal, data}

        steps ->
          trajectory = Episode.build_trajectory_from_steps(steps)
          data = spawn_trajectory_extraction(data, trajectory)
          {:keep_state, %{data | stopping: true, session_timer: nil}}
      end
    end
  end

  def collecting(:info, _msg, _data), do: :keep_state_and_data

  def collecting({:call, from}, _request, _data),
    do:
      {:keep_state_and_data,
       [{:reply, from, {:error, SessionError.exception(reason: :invalid_operation)}}]}

  # -- Extracting State --

  @doc false
  def extracting({:call, from}, :get_state, _data),
    do: {:keep_state_and_data, [{:reply, from, :extracting}]}

  def extracting({:call, from}, :get_id, data),
    do: {:keep_state_and_data, [{:reply, from, data.id}]}

  def extracting({:call, from}, :get_context, data) do
    {:keep_state_and_data, [{:reply, from, build_context(data)}]}
  end

  def extracting({:call, from}, _request, _data) do
    {:keep_state_and_data,
     [{:reply, from, {:error, SessionError.exception(reason: :extraction_in_progress)}}]}
  end

  def extracting(
        :info,
        {ref, {:ok, %Changeset{} = changeset, _trace}},
        %{extraction_task: ref} = data
      ) do
    Process.demonitor(ref, [:flush])

    if auto_commit_enabled?(data) do
      MemoryStore.apply_changeset(data.memory_store, changeset)
      emit_transition(data, :extracting, :idle)
      {:next_state, :idle, reset_session_data(data)}
    else
      emit_transition(data, :extracting, :ready)
      {:next_state, :ready, %{data | changeset: changeset, extraction_task: nil}}
    end
  end

  def extracting(:info, {ref, {:ok, %Changeset{} = changeset}}, %{extraction_task: ref} = data) do
    Process.demonitor(ref, [:flush])

    if auto_commit_enabled?(data) do
      MemoryStore.apply_changeset(data.memory_store, changeset)
      emit_transition(data, :extracting, :idle)
      {:next_state, :idle, reset_session_data(data)}
    else
      emit_transition(data, :extracting, :ready)
      {:next_state, :ready, %{data | changeset: changeset, extraction_task: nil}}
    end
  end

  def extracting(:info, {ref, {:error, reason}}, %{extraction_task: ref} = data) do
    Process.demonitor(ref, [:flush])
    Logger.error("extraction failed for session #{data.id}: #{inspect(reason)}")
    emit_transition(data, :extracting, :failed)
    {:next_state, :failed, %{data | extraction_task: nil}}
  end

  def extracting(:info, {:DOWN, ref, :process, _pid, _reason}, %{extraction_task: ref} = data) do
    Logger.error("extraction failed for session #{data.id}")
    emit_transition(data, :extracting, :failed)
    {:next_state, :failed, %{data | extraction_task: nil}}
  end

  def extracting(:info, _msg, _data), do: :keep_state_and_data

  # -- Failed State --

  @doc false
  def failed({:call, from}, :commit, data) do
    task = spawn_extraction(data)
    emit_transition(data, :failed, :extracting)
    {:next_state, :extracting, %{data | extraction_task: task.ref}, [{:reply, from, :ok}]}
  end

  def failed({:call, from}, :discard, data) do
    emit_transition(data, :failed, :idle)
    {:next_state, :idle, %{data | episode: nil, changeset: nil}, [{:reply, from, :ok}]}
  end

  def failed({:call, from}, :get_state, _data),
    do: {:keep_state_and_data, [{:reply, from, :failed}]}

  def failed({:call, from}, :get_id, data), do: {:keep_state_and_data, [{:reply, from, data.id}]}

  def failed({:call, from}, :get_context, data) do
    {:keep_state_and_data, [{:reply, from, build_context(data)}]}
  end

  def failed({:call, from}, _request, _data) do
    {:keep_state_and_data,
     [{:reply, from, {:error, SessionError.exception(reason: :session_failed)}}]}
  end

  # -- Ready State --

  @doc false
  def ready({:call, from}, :commit, data) do
    MemoryStore.apply_changeset(data.memory_store, data.changeset)
    emit_transition(data, :ready, :idle)
    {:next_state, :idle, %{data | episode: nil, changeset: nil}, [{:reply, from, :ok}]}
  end

  def ready({:call, from}, :discard, data) do
    emit_transition(data, :ready, :idle)
    {:next_state, :idle, %{data | episode: nil, changeset: nil}, [{:reply, from, :ok}]}
  end

  def ready({:call, from}, :get_state, _data),
    do: {:keep_state_and_data, [{:reply, from, :ready}]}

  def ready({:call, from}, :get_id, data), do: {:keep_state_and_data, [{:reply, from, data.id}]}

  def ready({:call, from}, :get_context, data) do
    {:keep_state_and_data, [{:reply, from, build_context(data)}]}
  end

  def ready({:call, from}, _request, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, SessionError.exception(reason: :not_idle)}}]}
  end

  # -- Private --

  defp enqueue_or_dispatch_append(data, observation, action, caller) do
    if data.append_task do
      Logger.debug(
        "session #{data.id} enqueuing append (task busy), new queue_size=#{:queue.len(data.append_queue) + 1}"
      )

      queue = :queue.in({observation, action, caller}, data.append_queue)
      {:keep_state, %{data | append_queue: queue}}
    else
      Logger.debug("session #{data.id} dispatching append immediately")
      {:keep_state, spawn_append(data, observation, action, caller)}
    end
  end

  defp spawn_append(data, observation, action, caller) do
    Logger.debug("session #{data.id} spawning append task on #{inspect(data.task_supervisor)}")
    prev_traj_id = data.episode.current_trajectory_id
    episode = data.episode

    opts = [
      repo_id: data.repo_id,
      session_id: data.id,
      llm: data.llm,
      embedding: data.embedding,
      config: data.config
    ]

    task =
      Task.Supervisor.async_nolink(data.task_supervisor, fn ->
        start = System.monotonic_time(:millisecond)
        result = Episode.append(episode, observation, action, opts)
        elapsed = System.monotonic_time(:millisecond) - start
        Logger.debug("session #{data.id} Episode.append took #{elapsed}ms")
        result
      end)

    %{data | append_task: task.ref, append_caller: caller, prev_trajectory_id: prev_traj_id}
  end

  defp dispatch_append(%{append_queue: queue} = data) do
    case :queue.out(queue) do
      {{:value, {observation, action, caller}}, rest} ->
        Logger.debug(
          "session #{data.id} dispatching next from queue, remaining=#{:queue.len(rest)}"
        )

        spawn_append(%{data | append_queue: rest}, observation, action, caller)

      {:empty, _} ->
        Logger.debug("session #{data.id} append queue empty, all done")
        data
    end
  end

  defp notify_append_caller(nil, _result), do: :ok
  defp notify_append_caller({:reply, from}, result), do: GenStateMachine.reply(from, result)
  defp notify_append_caller({:callback, fun}, result), do: fun.(result)

  defp spawn_extraction(data) do
    episode = data.episode

    opts = [
      repo_id: data.repo_id,
      session_id: data.id,
      llm: data.llm,
      embedding: data.embedding,
      config: data.config
    ]

    Task.Supervisor.async_nolink(data.task_supervisor, fn ->
      Structuring.extract(episode, opts)
    end)
  end

  defp build_context(data) do
    case data.episode do
      nil ->
        {:ok, nil}

      episode ->
        recent = Enum.take(episode.steps, -5)

        steps =
          Enum.map(recent, fn step ->
            "#{step.observation} -> #{step.action}"
          end)

        {:ok, %{goal: episode.goal, recent_steps: steps}}
    end
  end

  defp generate_id do
    "session_#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"
  end

  defp handle_close(data, from) do
    data = cancel_timers(data)

    if auto_commit_enabled?(data) do
      handle_auto_commit_close(data, from)
    else
      case Episode.close(data.episode) do
        {:ok, closed_episode} ->
          new_data = %{data | episode: closed_episode}
          task = spawn_extraction(new_data)
          emit_transition(data, :collecting, :extracting)

          {:next_state, :extracting, %{new_data | extraction_task: task.ref},
           [{:reply, from, :ok}]}

        {:error, _} = error ->
          {:keep_state_and_data, [{:reply, from, error}]}
      end
    end
  end

  defp auto_commit_enabled?(data) do
    data.config.session != nil and data.config.session.auto_commit
  end

  defp reset_timers(data) do
    data
    |> cancel_timers()
    |> start_timers()
  end

  defp cancel_timers(data) do
    cancel_and_flush_timer(data.flush_timer, :flush_timeout)
    cancel_and_flush_timer(data.session_timer, :session_timeout)
    %{data | flush_timer: nil, session_timer: nil}
  end

  defp handle_trajectory_extraction_failure(data, ref, reason) do
    traj_id = data.trajectory_tasks[ref]

    Logger.warning("trajectory extraction failed for #{traj_id}: #{inspect(reason)}")

    Notifier.safe_notify(
      data.notifier,
      data.repo_id,
      {:trajectory_extraction_failed, data.id, traj_id, reason, %{}}
    )

    trajectory_tasks = Map.delete(data.trajectory_tasks, ref)
    data = %{data | trajectory_tasks: trajectory_tasks}

    if data.stopping and map_size(data.trajectory_tasks) == 0 do
      Notifier.safe_notify(data.notifier, data.repo_id, {:session_expired, data.id, %{}})
      {:stop, :normal, data}
    else
      {:keep_state, data}
    end
  end

  defp cancel_and_flush_timer(nil, _msg), do: :ok

  defp cancel_and_flush_timer(ref, msg) do
    Process.cancel_timer(ref)
    receive do: (^msg -> :ok), after: (0 -> :ok)
  end

  defp start_timers(data) do
    if auto_commit_enabled?(data) do
      flush_ref = schedule_timer(:flush_timeout, data.config.session.flush_timeout_ms)
      session_ref = schedule_timer(:session_timeout, data.config.session.session_timeout_ms)
      %{data | flush_timer: flush_ref, session_timer: session_ref}
    else
      data
    end
  end

  defp schedule_timer(_msg, :infinity), do: nil
  defp schedule_timer(msg, ms) when is_integer(ms), do: Process.send_after(self(), msg, ms)

  defp uncommitted_current_steps(data) do
    current_traj_id = data.episode.current_trajectory_id

    if MapSet.member?(data.committed_trajectory_ids, current_traj_id) do
      []
    else
      Enum.filter(data.episode.steps, &(&1.trajectory_id == current_traj_id))
    end
  end

  defp flush_current_trajectory(data) do
    case uncommitted_current_steps(data) do
      [] ->
        %{data | flush_timer: nil}

      steps ->
        trajectory = Episode.build_trajectory_from_steps(steps)
        data = spawn_trajectory_extraction(data, trajectory)
        flush_triggered = Map.put(data.flush_triggered, trajectory.id, true)
        %{data | flush_triggered: flush_triggered, flush_timer: nil}
    end
  end

  defp handle_auto_commit_close(data, from) do
    case uncommitted_current_steps(data) do
      [] ->
        emit_transition(data, :collecting, :idle)
        {:next_state, :idle, reset_session_data(data), [{:reply, from, :ok}]}

      steps ->
        trajectory = Episode.build_trajectory_from_steps(steps)
        task = spawn_trajectory_task(data, trajectory)
        emit_transition(data, :collecting, :extracting)
        {:next_state, :extracting, %{data | extraction_task: task.ref}, [{:reply, from, :ok}]}
    end
  end

  defp maybe_spawn_trajectory_extraction(data, trajectory_id) do
    steps = Enum.filter(data.episode.steps, &(&1.trajectory_id == trajectory_id))

    if steps == [] do
      data
    else
      trajectory = Episode.build_trajectory_from_steps(steps)
      spawn_trajectory_extraction(data, trajectory)
    end
  end

  defp spawn_trajectory_extraction(data, trajectory) do
    task = spawn_trajectory_task(data, trajectory)
    trajectory_tasks = Map.put(data.trajectory_tasks, task.ref, trajectory.id)
    %{data | trajectory_tasks: trajectory_tasks}
  end

  defp spawn_trajectory_task(data, trajectory) do
    goal = data.episode.goal
    episode_id = data.episode.id

    opts = [
      repo_id: data.repo_id,
      session_id: data.id,
      llm: data.llm,
      embedding: data.embedding,
      config: data.config,
      episode_id: episode_id
    ]

    Task.Supervisor.async_nolink(data.task_supervisor, fn ->
      Structuring.extract_trajectory(trajectory, goal, opts)
    end)
  end

  defp reset_session_data(data) do
    data = cancel_timers(data)

    %{
      data
      | episode: nil,
        changeset: nil,
        trajectory_tasks: %{},
        committed_trajectory_ids: MapSet.new(),
        flush_triggered: %{},
        prev_trajectory_id: nil,
        stopping: false
    }
  end

  defp emit_transition(data, from_state, to_state) do
    Logger.debug("session #{data.id} transitioning #{from_state} -> #{to_state}")

    :telemetry.execute(
      [:mnemosyne, :session, :transition, :stop],
      %{duration: 0},
      %{session_id: data.id, repo_id: data.repo_id, from_state: from_state, to_state: to_state}
    )

    Notifier.safe_notify(
      data.notifier,
      data.repo_id,
      {:session_transition, data.id, from_state, to_state, %{}}
    )
  end
end
