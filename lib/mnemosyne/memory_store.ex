defmodule Mnemosyne.MemoryStore do
  @moduledoc """
  GenServer owning the graph backend state.

  Uses a two-lane queue for concurrent operations:
  - **Write lane**: serialized queue for apply_changeset and delete_nodes.
    Only one write runs at a time; others enqueue.
  - **Maintenance lane**: single slot for consolidate/decay operations.
  - **Recall lane**: multiple concurrent retrieval+reasoning tasks (unchanged).

  Write tasks return deltas applied to the GenServer's current backend state,
  not a captured snapshot. Maintenance tasks return updated backend state and
  are idempotent with respect to concurrent writes.
  """
  use GenServer

  require Logger

  alias Mnemosyne.Errors.Framework.PipelineError
  alias Mnemosyne.Graph
  alias Mnemosyne.Notifier
  alias Mnemosyne.Pipeline.Decay
  alias Mnemosyne.Pipeline.IntentMerger
  alias Mnemosyne.Pipeline.Reasoning
  alias Mnemosyne.Pipeline.Retrieval
  alias Mnemosyne.Pipeline.SemanticConsolidator
  alias Mnemosyne.Telemetry

  # -- Client API --

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Applies a changeset to the graph via the backend."
  @spec apply_changeset(GenServer.server(), Graph.Changeset.t()) :: :ok
  def apply_changeset(server, changeset) do
    GenServer.cast(server, {:apply_changeset, changeset})
  end

  @doc """
  Returns the current in-memory graph.

  Only works with backends that expose a `:graph` field in their state
  (e.g. `InMemory`). Returns an empty graph for other backends.
  """
  @spec get_graph(GenServer.server()) :: Graph.t()
  def get_graph(server) do
    GenServer.call(server, :get_graph)
  end

  @doc "Runs async retrieval + reasoning and returns the result."
  @spec recall(GenServer.server(), String.t(), keyword()) ::
          {:ok, Reasoning.ReasonedMemory.t()} | {:error, Mnemosyne.Errors.error()}
  def recall(server, query, opts \\ []) do
    GenServer.call(server, {:recall, query, opts}, :timer.seconds(120))
  end

  @doc "Fetches session context, augments the query, then runs recall."
  @spec recall_in_context(GenServer.server(), term(), String.t(), keyword()) ::
          {:ok, Reasoning.ReasonedMemory.t()} | {:error, Mnemosyne.Errors.error()}
  def recall_in_context(server, session_id, query, opts \\ []) do
    GenServer.call(server, {:recall_in_context, session_id, query, opts}, :timer.seconds(120))
  end

  @doc "Removes nodes from the graph via the backend."
  @spec delete_nodes(GenServer.server(), [String.t()]) :: :ok
  def delete_nodes(server, node_ids) do
    GenServer.cast(server, {:delete_nodes, node_ids})
  end

  @doc "Consolidates near-duplicate semantic nodes."
  @spec consolidate_semantics(GenServer.server(), keyword()) :: :ok
  def consolidate_semantics(server, opts \\ []) do
    GenServer.cast(server, {:consolidate_semantics, opts})
  end

  @doc "Prunes low-utility nodes via decay scoring."
  @spec decay_nodes(GenServer.server(), keyword()) :: :ok
  def decay_nodes(server, opts \\ []) do
    GenServer.cast(server, {:decay_nodes, opts})
  end

  @doc "Fetches a single node by ID from the backend."
  @spec get_node(GenServer.server(), String.t()) :: {:ok, struct() | nil} | {:error, term()}
  def get_node(server, node_id) do
    GenServer.call(server, {:get_node, node_id})
  end

  @doc "Fetches all nodes of the given types from the backend."
  @spec get_nodes_by_type(GenServer.server(), [atom()]) :: {:ok, [struct()]} | {:error, term()}
  def get_nodes_by_type(server, types) do
    GenServer.call(server, {:get_nodes_by_type, types})
  end

  @doc "Fetches metadata for the given node IDs."
  @spec get_metadata(GenServer.server(), [String.t()]) ::
          {:ok, %{String.t() => Mnemosyne.NodeMetadata.t()}} | {:error, term()}
  def get_metadata(server, node_ids) do
    GenServer.call(server, {:get_metadata, node_ids})
  end

  @doc "Fetches nodes by their IDs from the backend."
  @spec get_linked_nodes(GenServer.server(), [String.t()]) :: {:ok, [struct()]} | {:error, term()}
  def get_linked_nodes(server, node_ids) do
    GenServer.call(server, {:get_linked_nodes, node_ids})
  end

  @doc """
  Fetches the most recently created nodes of the given types, sorted by creation time.

  Returns up to `top_k` nodes paired with their metadata, newest first.
  Defaults to semantic and procedural node types.
  """
  @spec latest(GenServer.server(), pos_integer(), keyword()) ::
          {:ok, [{struct(), Mnemosyne.NodeMetadata.t()}]} | {:error, term()}
  def latest(server, top_k, opts \\ []) do
    GenServer.call(server, {:latest, top_k, opts})
  end

  @doc "Returns the config, llm, embedding, notifier, and repo_id for session creation."
  @spec get_session_defaults(GenServer.server()) :: %{
          config: term(),
          llm: module(),
          embedding: module(),
          notifier: module(),
          repo_id: String.t() | nil
        }
  def get_session_defaults(server) do
    GenServer.call(server, :get_session_defaults)
  end

  # -- Server Callbacks --

  @impl true
  def init(opts) do
    {backend_mod, backend_opts} = Keyword.fetch!(opts, :backend)

    case backend_mod.init(backend_opts) do
      {:ok, backend_state} ->
        state = %{
          repo_id: Keyword.get(opts, :repo_id),
          backend: {backend_mod, backend_state},
          config: Keyword.fetch!(opts, :config),
          llm: Keyword.fetch!(opts, :llm),
          embedding: Keyword.fetch!(opts, :embedding),
          notifier: Keyword.get(opts, :notifier, Mnemosyne.Notifier.Noop),
          task_supervisor: Keyword.fetch!(opts, :task_supervisor),
          pending_recalls: %{},
          write_queue: :queue.new(),
          write_active: nil,
          maintenance_active: nil
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:apply_changeset, changeset}, state) do
    {:noreply, enqueue_or_dispatch_write({:apply_changeset, changeset, nil}, state)}
  end

  @impl true
  def handle_cast({:delete_nodes, node_ids}, state) do
    {:noreply, enqueue_or_dispatch_write({:delete_nodes, node_ids, nil}, state)}
  end

  @impl true
  def handle_cast({:consolidate_semantics, opts}, state) do
    if state.maintenance_active == nil do
      {ref, operation} = spawn_maintenance_task({:consolidate_semantics, opts, nil}, state)
      new_state = %{state | maintenance_active: {ref, operation}}
      emit_queue_telemetry(new_state, :maintenance_start)
      {:noreply, new_state}
    else
      Logger.debug("maintenance already active, dropping consolidate request")
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:decay_nodes, opts}, state) do
    if state.maintenance_active == nil do
      {ref, operation} = spawn_maintenance_task({:decay_nodes, opts, nil}, state)
      new_state = %{state | maintenance_active: {ref, operation}}
      emit_queue_telemetry(new_state, :maintenance_start)
      {:noreply, new_state}
    else
      Logger.debug("maintenance already active, dropping decay request")
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:get_graph, _from, state) do
    {_backend_mod, backend_state} = state.backend
    {:reply, Map.get(backend_state, :graph, Graph.new()), state}
  end

  @impl true
  def handle_call({:get_node, node_id}, _from, state) do
    {backend_mod, backend_state} = state.backend

    case backend_mod.get_node(node_id, backend_state) do
      {:ok, node, _bs} -> {:reply, {:ok, node}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:get_nodes_by_type, types}, _from, state) do
    {backend_mod, backend_state} = state.backend

    case backend_mod.get_nodes_by_type(types, backend_state) do
      {:ok, nodes, _bs} -> {:reply, {:ok, nodes}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:get_metadata, node_ids}, _from, state) do
    {backend_mod, backend_state} = state.backend

    case backend_mod.get_metadata(node_ids, backend_state) do
      {:ok, metadata, _bs} -> {:reply, {:ok, metadata}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:get_linked_nodes, node_ids}, _from, state) do
    {backend_mod, backend_state} = state.backend

    case backend_mod.get_linked_nodes(node_ids, backend_state) do
      {:ok, nodes, _bs} -> {:reply, {:ok, nodes}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:latest, top_k, opts}, _from, state) do
    types = Keyword.get(opts, :types, [:semantic, :procedural])

    case fetch_nodes_with_metadata(types, state.backend) do
      {:ok, pairs} ->
        result =
          pairs
          |> Enum.sort_by(fn {_node, meta} -> meta.created_at end, {:desc, DateTime})
          |> Enum.take(top_k)

        {:reply, {:ok, result}, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:get_session_defaults, _from, state) do
    defaults = %{
      config: state.config,
      llm: state.llm,
      embedding: state.embedding,
      notifier: state.notifier,
      repo_id: state.repo_id
    }

    {:reply, defaults, state}
  end

  @impl true
  def handle_call({:recall, query, opts}, from, state) do
    session_id = Keyword.get(opts, :session_id)
    task = spawn_recall_task(state, query, opts)
    pending = Map.put(state.pending_recalls, task.ref, {from, query, session_id})
    {:noreply, %{state | pending_recalls: pending}}
  end

  @impl true
  def handle_call({:recall_in_context, session_id, query, opts}, from, state) do
    augmented_query = augment_query_with_context(session_id, query)
    opts_session_id = Keyword.get(opts, :session_id, session_id)
    task = spawn_recall_task(state, augmented_query, opts)
    pending = Map.put(state.pending_recalls, task.ref, {from, augmented_query, opts_session_id})
    {:noreply, %{state | pending_recalls: pending}}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    cond do
      match?({^ref, _}, state.write_active) ->
        handle_write_complete(ref, result, state)

      match?({^ref, _}, state.maintenance_active) ->
        handle_maintenance_complete(ref, result, state)

      Map.has_key?(state.pending_recalls, ref) ->
        handle_recall_complete(ref, result, state)

      true ->
        Logger.warning("Received result for unknown task ref: #{inspect(ref)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    cond do
      match?({^ref, _}, state.write_active) ->
        handle_write_crash(ref, reason, state)

      match?({^ref, _}, state.maintenance_active) ->
        handle_maintenance_crash(ref, reason, state)

      Map.has_key?(state.pending_recalls, ref) ->
        handle_recall_crash(ref, reason, state)

      true ->
        Logger.warning(
          "Received DOWN for unknown task ref: #{inspect(ref)}, reason: #{inspect(reason)}"
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("MemoryStore received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # -- Private: Write Lane --

  defp enqueue_or_dispatch_write(operation, state) do
    new_state =
      if state.write_active do
        queue = :queue.in(operation, state.write_queue)
        %{state | write_queue: queue}
      else
        {ref, operation} = spawn_write_task(operation, state)
        %{state | write_active: {ref, operation}}
      end

    emit_queue_telemetry(new_state, :enqueue)
    new_state
  end

  defp dispatch_write(state) do
    new_state =
      case :queue.out(state.write_queue) do
        {{:value, operation}, queue} ->
          {ref, operation} = spawn_write_task(operation, state)
          %{state | write_queue: queue, write_active: {ref, operation}}

        {:empty, _queue} ->
          %{state | write_active: nil}
      end

    emit_queue_telemetry(new_state, :dispatch)
    new_state
  end

  defp spawn_write_task({:apply_changeset, changeset, from}, state) do
    backend = state.backend
    llm = state.llm
    embedding = state.embedding
    config = state.config
    repo_id = state.repo_id

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        merge_opts = [
          repo_id: repo_id,
          backend: backend,
          llm: llm,
          embedding: embedding,
          config: config,
          value_function: config.value_function
        ]

        case IntentMerger.merge(changeset, merge_opts) do
          {:ok, merged_cs} -> {:ok, {:apply_changeset, merged_cs}}
          {:error, _} = error -> error
        end
      end)

    {task.ref, {:apply_changeset, from}}
  end

  defp spawn_write_task({:delete_nodes, node_ids, from}, state) do
    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        {:ok, {:delete_nodes, node_ids}}
      end)

    {task.ref, {:delete_nodes, from}}
  end

  defp handle_write_complete(ref, result, state) do
    Process.demonitor(ref, [:flush])
    {_ref, operation} = state.write_active

    case {result, operation} do
      {{:ok, {:apply_changeset, merged_cs}}, {:apply_changeset, from}} ->
        apply_changeset_to_backend(merged_cs, from, state)

      {{:ok, {:delete_nodes, node_ids}}, {:delete_nodes, from}} ->
        delete_nodes_from_backend(node_ids, from, state)

      {{:error, _} = error, {_op_type, from}} ->
        reply_and_dispatch(from, error, state)
    end
  end

  defp apply_changeset_to_backend(merged_cs, from, state) do
    {backend_mod, backend_state} = state.backend

    with {:ok, new_bs} <- backend_mod.apply_changeset(merged_cs, backend_state),
         {:ok, final_bs} <- maybe_update_metadata(backend_mod, merged_cs.metadata, new_bs) do
      Notifier.safe_notify(state.notifier, state.repo_id, {:changeset_applied, merged_cs, %{}})
      if from, do: GenServer.reply(from, :ok)
      {:noreply, dispatch_write(%{state | backend: {backend_mod, final_bs}})}
    else
      {:error, _} = error -> reply_and_dispatch(from, error, state)
    end
  end

  defp delete_nodes_from_backend(node_ids, from, state) do
    {backend_mod, backend_state} = state.backend

    case backend_mod.delete_nodes(node_ids, backend_state) do
      {:ok, new_bs} ->
        Notifier.safe_notify(state.notifier, state.repo_id, {:nodes_deleted, node_ids, %{}})
        if from, do: GenServer.reply(from, :ok)
        {:noreply, dispatch_write(%{state | backend: {backend_mod, new_bs}})}

      {:error, _} = error ->
        reply_and_dispatch(from, error, state)
    end
  end

  defp reply_and_dispatch(from, error, state) do
    if from, do: GenServer.reply(from, error)
    {:noreply, dispatch_write(%{state | write_active: nil})}
  end

  defp handle_write_crash(ref, reason, state) do
    Process.demonitor(ref, [:flush])
    {_ref, {_op_type, from}} = state.write_active

    Logger.error("Write task crashed: #{inspect(reason)}")

    if from do
      GenServer.reply(from, {:error, PipelineError.exception(reason: {:task_crashed, reason})})
    end

    {:noreply, dispatch_write(%{state | write_active: nil})}
  end

  # -- Private: Maintenance Lane --

  defp spawn_maintenance_task({:consolidate_semantics, opts, from}, state) do
    backend = state.backend
    config = state.config
    repo_id = state.repo_id

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        consolidation_opts = Keyword.merge(opts, backend: backend, config: config)

        Telemetry.span([:consolidator, :consolidate], %{repo_id: repo_id}, fn ->
          run_maintenance(&SemanticConsolidator.consolidate/1, consolidation_opts)
        end)
      end)

    {task.ref, {:consolidate_semantics, from}}
  end

  defp spawn_maintenance_task({:decay_nodes, opts, from}, state) do
    backend = state.backend
    config = state.config
    repo_id = state.repo_id

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        decay_opts = Keyword.merge(opts, backend: backend, config: config)

        Telemetry.span([:decay, :prune], %{repo_id: repo_id}, fn ->
          run_maintenance(&Decay.decay/1, decay_opts)
        end)
      end)

    {task.ref, {:decay_nodes, from}}
  end

  defp run_maintenance(fun, opts) do
    case fun.(opts) do
      {:ok, result, updated_backend} ->
        {{:ok, result, updated_backend}, %{checked: result.checked, deleted: result.deleted}}

      {:error, _} = error ->
        {error, %{}}
    end
  end

  defp handle_maintenance_complete(ref, result, state) do
    Process.demonitor(ref, [:flush])
    {_ref, {op_type, from}} = state.maintenance_active

    new_state =
      case result do
        {:ok, op_result, updated_backend} ->
          notify_maintenance(op_type, op_result, state)
          if from, do: GenServer.reply(from, {:ok, op_result})
          %{state | backend: updated_backend, maintenance_active: nil}

        {:error, _} = error ->
          if from, do: GenServer.reply(from, error)
          %{state | maintenance_active: nil}
      end

    emit_queue_telemetry(new_state, :maintenance_complete)
    {:noreply, new_state}
  end

  defp handle_maintenance_crash(ref, reason, state) do
    Process.demonitor(ref, [:flush])
    {_ref, {_op_type, from}} = state.maintenance_active

    Logger.error("Maintenance task crashed: #{inspect(reason)}")

    if from do
      GenServer.reply(from, {:error, PipelineError.exception(reason: {:task_crashed, reason})})
    end

    new_state = %{state | maintenance_active: nil}
    emit_queue_telemetry(new_state, :maintenance_complete)
    {:noreply, new_state}
  end

  defp notify_maintenance(:consolidate_semantics, result, state) do
    Notifier.safe_notify(
      state.notifier,
      state.repo_id,
      {:consolidation_completed,
       %{checked: result.checked, deleted: result.deleted, deleted_ids: result.deleted_ids}, %{}}
    )
  end

  defp notify_maintenance(:decay_nodes, result, state) do
    Notifier.safe_notify(
      state.notifier,
      state.repo_id,
      {:decay_completed,
       %{checked: result.checked, deleted: result.deleted, deleted_ids: result.deleted_ids}, %{}}
    )
  end

  # -- Private: Recall Lane --

  defp handle_recall_complete(ref, result, state) do
    {{from, query, session_id}, pending} = Map.pop(state.pending_recalls, ref)
    Process.demonitor(ref, [:flush])
    metadata = %{session_id: session_id}

    case result do
      {:ok, reasoned, trace} ->
        metadata = Map.put(metadata, :trace, trace)

        Notifier.safe_notify(
          state.notifier,
          state.repo_id,
          {:recall_executed, query, {:ok, reasoned}, metadata}
        )

        GenServer.reply(from, {:ok, reasoned})

      {:error, reason} ->
        Logger.warning("Recall failed for query #{inspect(query)}: #{inspect(reason)}")

        Notifier.safe_notify(
          state.notifier,
          state.repo_id,
          {:recall_failed, query, reason, metadata}
        )

        GenServer.reply(from, {:error, reason})
    end

    {:noreply, %{state | pending_recalls: pending}}
  end

  defp handle_recall_crash(ref, reason, state) do
    {{from, _query, _session_id}, pending} = Map.pop(state.pending_recalls, ref)
    GenServer.reply(from, {:error, PipelineError.exception(reason: {:task_crashed, reason})})
    {:noreply, %{state | pending_recalls: pending}}
  end

  # -- Private: Common --

  defp spawn_recall_task(state, query, opts) do
    config = state.config
    llm = state.llm
    embedding = state.embedding
    value_fn = config.value_function
    max_hops = Keyword.get(opts, :max_hops, 2)
    session_id = Keyword.get(opts, :session_id)
    backend = state.backend
    repo_id = state.repo_id

    Task.Supervisor.async_nolink(state.task_supervisor, fn ->
      retrieval_opts = [
        repo_id: repo_id,
        session_id: session_id,
        llm: llm,
        embedding: embedding,
        backend: backend,
        value_function: value_fn,
        config: config,
        max_hops: max_hops
      ]

      with {:ok, result, trace} <- Retrieval.retrieve(query, retrieval_opts),
           {:ok, reasoned} <-
             Reasoning.reason(result,
               repo_id: repo_id,
               session_id: session_id,
               llm: llm,
               query: query,
               config: config
             ) do
        {:ok, reasoned, trace}
      end
    end)
  end

  defp fetch_nodes_with_metadata(types, {backend_mod, backend_state}) do
    with {:ok, nodes, _bs} <- backend_mod.get_nodes_by_type(types, backend_state),
         node_ids = Enum.map(nodes, &Mnemosyne.Graph.Node.id/1),
         {:ok, metadata_map, _bs} <- backend_mod.get_metadata(node_ids, backend_state) do
      pairs =
        nodes
        |> Enum.map(fn node -> {node, Map.get(metadata_map, Mnemosyne.Graph.Node.id(node))} end)
        |> Enum.filter(fn {_node, meta} -> meta != nil end)

      {:ok, pairs}
    end
  end

  defp maybe_update_metadata(_backend_mod, metadata, bs) when map_size(metadata) == 0,
    do: {:ok, bs}

  defp maybe_update_metadata(backend_mod, metadata, bs),
    do: backend_mod.update_metadata(metadata, bs)

  defp emit_queue_telemetry(state, event) do
    :telemetry.execute(
      [:mnemosyne, :memory_store, :queue],
      %{
        write_queue_size: :queue.len(state.write_queue),
        write_active: if(state.write_active, do: 1, else: 0),
        maintenance_active: if(state.maintenance_active, do: 1, else: 0),
        pending_recalls: map_size(state.pending_recalls)
      },
      %{repo_id: state.repo_id, event: event}
    )
  end

  defp augment_query_with_context(session_ref, query) do
    case Mnemosyne.Session.get_context(session_ref) do
      {:ok, %{goal: goal, recent_steps: steps}} when steps != [] ->
        step_summary =
          steps
          |> Enum.take(-3)
          |> Enum.map_join("\n", fn s -> "- #{s}" end)

        "Goal: #{goal}\nRecent context:\n#{step_summary}\n\nQuery: #{query}"

      _ ->
        query
    end
  end
end
