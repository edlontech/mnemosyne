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
          extraction_task: reference() | nil
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
    :extraction_task
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
  """
  @spec append(GenServer.server(), String.t(), String.t()) ::
          :ok | {:error, Mnemosyne.Errors.error()}
  def append(server, observation, action) do
    GenStateMachine.call(server, {:append, observation, action}, :timer.seconds(60))
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
    {:next_state, :collecting, %{data | episode: episode}, [{:reply, from, :ok}]}
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
    opts = [
      repo_id: data.repo_id,
      llm: data.llm,
      embedding: data.embedding,
      config: data.config
    ]

    case Episode.append(data.episode, observation, action, opts) do
      {:ok, episode} ->
        {:keep_state, %{data | episode: episode}, [{:reply, from, :ok}]}

      {:error, _} = error ->
        {:keep_state_and_data, [{:reply, from, error}]}
    end
  end

  def collecting({:call, from}, :close, data) do
    case Episode.close(data.episode) do
      {:ok, closed_episode} ->
        new_data = %{data | episode: closed_episode}
        task = spawn_extraction(new_data)
        emit_transition(data, :collecting, :extracting)
        {:next_state, :extracting, %{new_data | extraction_task: task.ref}, [{:reply, from, :ok}]}

      {:error, _} = error ->
        {:keep_state_and_data, [{:reply, from, error}]}
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

  def extracting(:info, {ref, {:ok, %Changeset{} = changeset}}, %{extraction_task: ref} = data) do
    Process.demonitor(ref, [:flush])
    emit_transition(data, :extracting, :ready)
    {:next_state, :ready, %{data | changeset: changeset, extraction_task: nil}}
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
    case MemoryStore.apply_changeset(data.memory_store, data.changeset) do
      :ok ->
        emit_transition(data, :ready, :idle)
        {:next_state, :idle, %{data | episode: nil, changeset: nil}, [{:reply, from, :ok}]}

      {:error, _} = error ->
        {:keep_state_and_data, [{:reply, from, error}]}
    end
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

  defp spawn_extraction(data) do
    episode = data.episode

    opts = [
      repo_id: data.repo_id,
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
      {:session_transition, data.id, from_state, to_state}
    )
  end
end
