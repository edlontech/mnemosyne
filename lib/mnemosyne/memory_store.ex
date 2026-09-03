defmodule Mnemosyne.MemoryStore do
  @moduledoc """
  GenServer owning the graph backend state.

  Uses a two-lane queue for concurrent operations:
  - **Write lane**: serialized queue for changesets, ingestion commits, and deletions.
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
  alias Mnemosyne.Errors.Invalid.IngestionError
  alias Mnemosyne.Graph
  alias Mnemosyne.IngestionReceipt
  alias Mnemosyne.ModelCall.Context
  alias Mnemosyne.NodeMetadata
  alias Mnemosyne.Notifier
  alias Mnemosyne.Pipeline.Decay
  alias Mnemosyne.Pipeline.EpisodicValidation
  alias Mnemosyne.Pipeline.GraphRepair
  alias Mnemosyne.Pipeline.Ingestion
  alias Mnemosyne.Pipeline.IntentMerger
  alias Mnemosyne.Pipeline.Reasoning
  alias Mnemosyne.Pipeline.RecallResult
  alias Mnemosyne.Pipeline.Retrieval
  alias Mnemosyne.Pipeline.Retrieval.TouchedNode
  alias Mnemosyne.Pipeline.SemanticConsolidator
  alias Mnemosyne.Pipeline.TagDeduplicator
  alias Mnemosyne.Telemetry

  # -- Client API --

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Stores a complete trajectory or returns an error without exposing partial memory."
  @spec ingest(GenServer.server(), Mnemosyne.Trajectory.t(), keyword()) ::
          {:ok, IngestionReceipt.t()} | {:error, Mnemosyne.Errors.error()}
  def ingest(server, trajectory, opts \\ []) do
    with {:ok, digest} <- Ingestion.prepare(trajectory) do
      GenServer.call(server, {:ingest, trajectory, digest, opts}, :infinity)
    end
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
          {:ok, RecallResult.t()} | {:error, Mnemosyne.Errors.error()}
  def recall(server, query, opts \\ []) do
    augmented_query = augment_query_with_context(Keyword.get(opts, :context), query)

    GenServer.call(
      server,
      {:recall, augmented_query, Keyword.delete(opts, :context)},
      :timer.seconds(120)
    )
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

  @doc "Validates episodic grounding and penalizes weakly grounded nodes."
  @spec validate_episodic(GenServer.server(), keyword()) :: :ok
  def validate_episodic(server, opts \\ []) do
    GenServer.cast(server, {:validate_episodic, opts})
  end

  @doc "Strips dangling link references and deletes orphaned routing nodes."
  @spec repair_graph(GenServer.server(), keyword()) :: :ok
  def repair_graph(server, opts \\ []) do
    GenServer.cast(server, {:repair_graph, opts})
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

  # -- Server Callbacks --

  @impl true
  def init(opts) do
    {backend_mod, backend_opts} = Keyword.fetch!(opts, :backend)
    repo_id = Keyword.get(opts, :repo_id)
    backend_opts = Keyword.put_new(backend_opts, :repo_id, repo_id)

    case backend_mod.init(backend_opts) do
      {:ok, backend_state} ->
        state = %{
          repo_id: Keyword.get(opts, :repo_id),
          telemetry_labels: Keyword.get(opts, :telemetry_labels, %{}),
          backend: {backend_mod, backend_state},
          config: Keyword.fetch!(opts, :config),
          llm: Keyword.fetch!(opts, :llm),
          embedding: Keyword.fetch!(opts, :embedding),
          notifier: Keyword.get(opts, :notifier, Mnemosyne.Notifier.Noop),
          task_supervisor: Keyword.fetch!(opts, :task_supervisor),
          pending_ingestions: %{},
          ingestion_tasks: %{},
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
  def handle_cast({:validate_episodic, opts}, state) do
    if state.maintenance_active == nil do
      {ref, operation} = spawn_maintenance_task({:validate_episodic, opts, nil}, state)
      new_state = %{state | maintenance_active: {ref, operation}}
      emit_queue_telemetry(new_state, :maintenance_start)
      {:noreply, new_state}
    else
      Logger.debug("maintenance already active, dropping validation request")
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:repair_graph, opts}, state) do
    if state.maintenance_active == nil do
      {ref, operation} = spawn_maintenance_task({:repair_graph, opts, nil}, state)
      new_state = %{state | maintenance_active: {ref, operation}}
      emit_queue_telemetry(new_state, :maintenance_start)
      {:noreply, new_state}
    else
      Logger.debug("maintenance already active, dropping repair request")
      {:noreply, state}
    end
  end

  @impl true
  def handle_call({:ingest, trajectory, digest, opts}, from, state) do
    source_id = trajectory.source_id

    case Map.get(state.pending_ingestions, source_id) do
      %{digest: ^digest} = pending ->
        pending = %{pending | waiters: [from | pending.waiters]}
        {:noreply, put_in(state.pending_ingestions[source_id], pending)}

      %{digest: _other_digest} ->
        error = source_conflict(source_id)
        notify_ingestion_failure(source_id, error, state)
        {:reply, error, state}

      nil ->
        admit_ingestion(trajectory, digest, opts, from, state)
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

    case backend_mod.get_linked_nodes(node_ids, nil, backend_state) do
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
  def handle_call({:recall, query, opts}, from, state) do
    source_id = Keyword.get(opts, :source_id)
    task = spawn_recall_task(state, query, opts)
    pending = Map.put(state.pending_recalls, task.ref, {from, query, source_id})
    {:noreply, %{state | pending_recalls: pending}}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    cond do
      match?({^ref, _}, state.write_active) ->
        handle_write_complete(ref, result, state)

      match?({^ref, _}, state.maintenance_active) ->
        handle_maintenance_complete(ref, result, state)

      Map.has_key?(state.ingestion_tasks, ref) ->
        handle_ingestion_complete(ref, result, state)

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

      Map.has_key?(state.ingestion_tasks, ref) ->
        handle_ingestion_crash(ref, reason, state)

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

  # -- Private: Ingestion --

  defp admit_ingestion(trajectory, digest, opts, from, state) do
    {backend_mod, backend_state} = state.backend
    fingerprint_version = Ingestion.fingerprint_version()

    case backend_mod.get_ingestion(trajectory.source_id, backend_state) do
      {:ok,
       %{
         fingerprint_version: version,
         payload_digest: stored_digest,
         receipt: receipt
       }, _backend_state}
      when version == fingerprint_version and stored_digest == digest ->
        {:reply, {:ok, receipt}, state}

      {:ok, nil, _backend_state} ->
        {:noreply, start_ingestion(trajectory, digest, opts, from, state)}

      {:ok, _record, _backend_state} ->
        error = source_conflict(trajectory.source_id)
        notify_ingestion_failure(trajectory.source_id, error, state)
        {:reply, error, state}

      {:error, _reason} = error ->
        notify_ingestion_failure(trajectory.source_id, error, state)
        {:reply, error, state}
    end
  end

  defp start_ingestion(trajectory, digest, opts, from, state) do
    execution_opts =
      opts
      |> Keyword.put_new(:config, state.config)
      |> Keyword.put_new(:llm, state.llm)
      |> Keyword.put_new(:embedding, state.embedding)
      |> Keyword.put(:repo_id, state.repo_id)
      |> Keyword.put(:model_context, model_context(state, :ingest, trajectory.source_id))

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        Ingestion.run(trajectory, execution_opts)
      end)

    pending = %{
      digest: digest,
      waiters: [from],
      task_ref: task.ref,
      execution_opts: execution_opts
    }

    %{
      state
      | pending_ingestions: Map.put(state.pending_ingestions, trajectory.source_id, pending),
        ingestion_tasks: Map.put(state.ingestion_tasks, task.ref, trajectory.source_id)
    }
  end

  defp handle_ingestion_complete(ref, {:ok, changeset}, state) do
    Process.demonitor(ref, [:flush])
    source_id = Map.fetch!(state.ingestion_tasks, ref)
    %{digest: digest} = Map.fetch!(state.pending_ingestions, source_id)
    operation = {:commit_ingestion, source_id, digest, changeset}
    {:noreply, enqueue_or_dispatch_write(operation, state)}
  end

  defp handle_ingestion_complete(ref, {:error, _reason} = error, state) do
    Process.demonitor(ref, [:flush])
    source_id = Map.fetch!(state.ingestion_tasks, ref)
    notify_ingestion_failure(source_id, error, state)
    {:noreply, complete_ingestion(state, source_id, error)}
  end

  defp handle_ingestion_crash(ref, reason, state) do
    source_id = Map.fetch!(state.ingestion_tasks, ref)
    error = {:error, PipelineError.exception(reason: {:task_crashed, reason})}
    notify_ingestion_failure(source_id, error, state)
    {:noreply, complete_ingestion(state, source_id, error)}
  end

  defp source_conflict(source_id) do
    {:error, IngestionError.exception(source_id: source_id, reason: :source_conflict)}
  end

  defp notify_ingestion_success(receipt, state) do
    Notifier.safe_notify(
      state.notifier,
      state.repo_id,
      {:trajectory_ingested, receipt,
       Map.put(ingestion_metadata(state, receipt.source_id), :node_ids, receipt.node_ids)}
    )
  end

  defp notify_ingestion_failure(source_id, {:error, reason}, state) do
    Notifier.safe_notify(
      state.notifier,
      state.repo_id,
      {:trajectory_ingestion_failed, source_id, reason, ingestion_metadata(state, source_id)}
    )
  end

  defp ingestion_metadata(state, source_id), do: %{repo_id: state.repo_id, source_id: source_id}

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

    execution_opts =
      Keyword.put(
        [
          repo_id: state.repo_id,
          llm: state.llm,
          embedding: state.embedding,
          config: state.config
        ],
        :model_context,
        model_context(state, :apply_changeset)
      )

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        with {:ok, merged_cs} <- merge_changeset(changeset, backend, execution_opts) do
          {:ok, {:apply_changeset, merged_cs}}
        end
      end)

    {task.ref, {:apply_changeset, from}}
  end

  defp spawn_write_task({:commit_ingestion, source_id, digest, changeset}, state) do
    backend = state.backend
    pending = Map.fetch!(state.pending_ingestions, source_id)

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        with {:ok, merged_cs} <- merge_changeset(changeset, backend, pending.execution_opts) do
          {:ok, {:commit_ingestion, source_id, digest, merged_cs}}
        end
      end)

    {task.ref, {:commit_ingestion, source_id}}
  end

  defp spawn_write_task({:delete_nodes, node_ids, from}, state) do
    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        {:ok, {:delete_nodes, node_ids}}
      end)

    {task.ref, {:delete_nodes, from}}
  end

  defp merge_changeset(changeset, backend, execution_opts) do
    config = Keyword.fetch!(execution_opts, :config)

    merge_opts =
      execution_opts
      |> Keyword.put(:backend, backend)
      |> Keyword.put(:value_function, config.value_function)

    case TagDeduplicator.deduplicate(changeset, merge_opts) do
      {:ok, deduped_cs} -> IntentMerger.merge(deduped_cs, merge_opts)
      {:error, _reason} = error -> error
    end
  end

  defp handle_write_complete(ref, result, state) do
    Process.demonitor(ref, [:flush])
    {_ref, operation} = state.write_active

    case {result, operation} do
      {{:ok, {:apply_changeset, merged_cs}}, {:apply_changeset, from}} ->
        apply_changeset_to_backend(merged_cs, from, state)

      {{:ok, {:commit_ingestion, source_id, digest, merged_cs}}, {:commit_ingestion, source_id}} ->
        commit_ingestion_to_backend(source_id, digest, merged_cs, state)

      {{:ok, {:delete_nodes, node_ids}}, {:delete_nodes, from}} ->
        delete_nodes_from_backend(node_ids, from, state)

      {{:error, reason} = error, {:commit_ingestion, source_id}} ->
        Logger.error("Write task failed (commit_ingestion): #{inspect(reason)}")
        {:noreply, fail_ingestion_and_dispatch(source_id, error, state)}

      {{:error, reason} = error, {op_type, from}} ->
        Logger.error("Write task failed (#{op_type}): #{inspect(reason)}")
        notify_write_failure(op_type, reason, state)
        reply_and_dispatch(from, error, state)
    end
  end

  defp commit_ingestion_to_backend(source_id, digest, merged_cs, state) do
    {backend_mod, backend_state} = state.backend

    receipt = %IngestionReceipt{
      source_id: source_id,
      node_ids: Enum.map(merged_cs.additions, &Mnemosyne.Graph.Node.id/1),
      stored_at: DateTime.utc_now()
    }

    record = %{
      source_id: source_id,
      payload_digest: digest,
      fingerprint_version: Ingestion.fingerprint_version(),
      receipt: receipt
    }

    case backend_mod.commit_ingestion(record, merged_cs, backend_state) do
      {:ok, :inserted, authoritative_receipt, final_bs} ->
        new_state = Map.put(state, :backend, {backend_mod, final_bs})
        notify_ingestion_success(authoritative_receipt, new_state)
        {:noreply, complete_committed_ingestion(source_id, authoritative_receipt, new_state)}

      {:ok, :existing, authoritative_receipt, final_bs} ->
        new_state = Map.put(state, :backend, {backend_mod, final_bs})
        {:noreply, complete_committed_ingestion(source_id, authoritative_receipt, new_state)}

      {:error, reason} = error ->
        Logger.error("Backend commit_ingestion failed: #{inspect(reason)}")
        {:noreply, fail_ingestion_and_dispatch(source_id, error, state)}
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
      {:error, reason} = error ->
        Logger.error("Backend apply_changeset failed: #{inspect(reason)}")
        notify_write_failure(:apply_changeset, reason, state)
        reply_and_dispatch(from, error, state)
    end
  end

  defp delete_nodes_from_backend(node_ids, from, state) do
    {backend_mod, backend_state} = state.backend

    case backend_mod.delete_nodes(node_ids, backend_state) do
      {:ok, new_bs} ->
        Notifier.safe_notify(state.notifier, state.repo_id, {:nodes_deleted, node_ids, %{}})
        if from, do: GenServer.reply(from, :ok)
        {:noreply, dispatch_write(%{state | backend: {backend_mod, new_bs}})}

      {:error, reason} = error ->
        Logger.error("Backend delete_nodes failed: #{inspect(reason)}")
        notify_write_failure(:delete_nodes, reason, state)
        reply_and_dispatch(from, error, state)
    end
  end

  defp reply_and_dispatch(from, error, state) do
    if from, do: GenServer.reply(from, error)
    {:noreply, dispatch_write(%{state | write_active: nil})}
  end

  defp notify_write_failure(operation, reason, state) do
    Notifier.safe_notify(
      state.notifier,
      state.repo_id,
      {:write_failed, operation, reason, %{}}
    )
  end

  defp handle_write_crash(ref, reason, state) do
    Process.demonitor(ref, [:flush])
    {_ref, operation} = state.write_active

    case operation do
      {:commit_ingestion, source_id} ->
        Logger.error("Write task crashed (commit_ingestion): #{inspect(reason)}")
        error = {:error, PipelineError.exception(reason: {:task_crashed, reason})}
        {:noreply, fail_ingestion_and_dispatch(source_id, error, state)}

      {op_type, from} ->
        Logger.error("Write task crashed (#{op_type}): #{inspect(reason)}")

        Notifier.safe_notify(
          state.notifier,
          state.repo_id,
          {:write_crashed, op_type, reason, %{}}
        )

        if from do
          GenServer.reply(
            from,
            {:error, PipelineError.exception(reason: {:task_crashed, reason})}
          )
        end

        {:noreply, dispatch_write(%{state | write_active: nil})}
    end
  end

  defp complete_committed_ingestion(source_id, receipt, state) do
    state
    |> complete_ingestion(source_id, {:ok, receipt})
    |> dispatch_write()
  end

  defp fail_ingestion_and_dispatch(source_id, error, state) do
    notify_ingestion_failure(source_id, error, state)

    state
    |> complete_ingestion(source_id, error)
    |> Map.put(:write_active, nil)
    |> dispatch_write()
  end

  defp complete_ingestion(state, source_id, result) do
    {pending, pending_ingestions} = Map.pop!(state.pending_ingestions, source_id)
    Enum.each(pending.waiters, &GenServer.reply(&1, result))

    %{
      state
      | pending_ingestions: pending_ingestions,
        ingestion_tasks: Map.delete(state.ingestion_tasks, pending.task_ref)
    }
  end

  # -- Private: Maintenance Lane --

  defp spawn_maintenance_task({:consolidate_semantics, opts, from}, state) do
    backend = state.backend
    config = state.config
    repo_id = state.repo_id
    llm = state.llm
    embedding = state.embedding
    context = model_context(state, :consolidate_semantics)

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        consolidation_opts =
          opts
          |> Keyword.merge(backend: backend, config: config, llm: llm, embedding: embedding)
          |> Keyword.put(:model_context, context)

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

  defp spawn_maintenance_task({:validate_episodic, opts, from}, state) do
    backend = state.backend
    config = state.config
    repo_id = state.repo_id

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        validation_opts = Keyword.merge(opts, backend: backend, config: config)

        Telemetry.span([:episodic_validation, :validate], %{repo_id: repo_id}, fn ->
          run_validation(&EpisodicValidation.validate/1, validation_opts)
        end)
      end)

    {task.ref, {:validate_episodic, from}}
  end

  defp spawn_maintenance_task({:repair_graph, opts, from}, state) do
    backend = state.backend
    repo_id = state.repo_id

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        repair_opts = Keyword.put(opts, :backend, backend)

        Telemetry.span([:graph_repair, :repair], %{repo_id: repo_id}, fn ->
          run_repair(&GraphRepair.repair/1, repair_opts)
        end)
      end)

    {task.ref, {:repair_graph, from}}
  end

  defp run_maintenance(fun, opts) do
    case fun.(opts) do
      {:ok, result, updated_backend} ->
        {{:ok, result, updated_backend}, %{checked: result.checked, deleted: result.deleted}}

      {:error, _} = error ->
        {error, %{}}
    end
  end

  defp run_validation(fun, opts) do
    case fun.(opts) do
      {:ok, result, updated_backend} ->
        {{:ok, result, updated_backend},
         %{checked: result.checked, penalized: result.penalized, orphaned: result.orphaned}}

      {:error, _} = error ->
        {error, %{}}
    end
  end

  defp run_repair(fun, opts) do
    case fun.(opts) do
      {:ok, result, updated_backend} ->
        {{:ok, result, updated_backend},
         %{
           checked: result.checked,
           repaired_nodes: result.repaired_nodes,
           dangling_refs: result.dangling_refs,
           orphans_deleted: result.orphans_deleted
         }}

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
       %{
         checked: result.checked,
         deleted: result.deleted,
         merged: result.merged,
         deleted_ids: result.deleted_ids
       }, %{}}
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

  defp notify_maintenance(:repair_graph, result, state) do
    Notifier.safe_notify(
      state.notifier,
      state.repo_id,
      {:repair_completed,
       %{
         checked: result.checked,
         repaired_nodes: result.repaired_nodes,
         dangling_refs: result.dangling_refs,
         orphans_deleted: result.orphans_deleted,
         orphan_ids: result.orphan_ids
       }, %{}}
    )
  end

  defp notify_maintenance(:validate_episodic, result, state) do
    Notifier.safe_notify(
      state.notifier,
      state.repo_id,
      {:validation_completed,
       %{checked: result.checked, penalized: result.penalized, orphaned: result.orphaned}, %{}}
    )
  end

  # -- Private: Recall Lane --

  defp handle_recall_complete(ref, result, state) do
    {{from, query, source_id}, pending} = Map.pop(state.pending_recalls, ref)
    Process.demonitor(ref, [:flush])
    metadata = %{source_id: source_id}

    case result do
      {:ok, %RecallResult{} = recall_result} ->
        metadata = Map.put(metadata, :trace, recall_result.trace)

        Notifier.safe_notify(
          state.notifier,
          state.repo_id,
          {:recall_executed, query, {:ok, recall_result}, metadata}
        )

        GenServer.reply(from, {:ok, recall_result})

        backend = update_access_metadata(recall_result.touched_nodes, state.backend)
        {:noreply, %{state | pending_recalls: pending, backend: backend}}

      {:error, reason} ->
        Logger.warning("Recall failed for query #{inspect(query)}: #{inspect(reason)}")

        Notifier.safe_notify(
          state.notifier,
          state.repo_id,
          {:recall_failed, query, reason, metadata}
        )

        GenServer.reply(from, {:error, reason})
        {:noreply, %{state | pending_recalls: pending}}
    end
  end

  defp handle_recall_crash(ref, reason, state) do
    {{from, _query, _source_id}, pending} = Map.pop(state.pending_recalls, ref)
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
    source_id = Keyword.get(opts, :source_id)
    backend = state.backend
    repo_id = state.repo_id
    verbosity = config.trace_verbosity
    context = model_context(state, :recall, source_id)

    Task.Supervisor.async_nolink(state.task_supervisor, fn ->
      retrieval_opts =
        Keyword.put(
          [
            repo_id: repo_id,
            source_id: source_id,
            llm: llm,
            embedding: embedding,
            backend: backend,
            value_function: value_fn,
            config: config,
            max_hops: max_hops
          ],
          :model_context,
          context
        )

      reasoning_opts =
        Keyword.put(
          [
            repo_id: repo_id,
            source_id: source_id,
            llm: llm,
            query: query,
            config: config
          ],
          :model_context,
          context
        )

      with {:ok, result, trace} <- Retrieval.retrieve(query, retrieval_opts),
           {:ok, reasoned} <- Reasoning.reason(result, reasoning_opts) do
        touched_nodes =
          result.candidates
          |> Map.values()
          |> List.flatten()
          |> Enum.map(&TouchedNode.from_tagged(&1, verbosity))
          |> Enum.sort_by(& &1.score, :desc)

        {:ok, %RecallResult{reasoned: reasoned, touched_nodes: touched_nodes, trace: trace}}
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

  defp update_access_metadata(touched_nodes, {backend_mod, backend_state}) do
    node_ids = Enum.map(touched_nodes, & &1.id)
    do_update_access_metadata(node_ids, backend_mod, backend_state)
  end

  defp do_update_access_metadata([], backend_mod, backend_state),
    do: {backend_mod, backend_state}

  defp do_update_access_metadata(ids, backend_mod, backend_state) do
    with {:ok, current_meta, bs} <- backend_mod.get_metadata(ids, backend_state),
         updated_meta =
           Map.new(current_meta, fn {id, meta} ->
             {id, NodeMetadata.record_access(meta)}
           end),
         {:ok, bs} <- backend_mod.update_metadata(updated_meta, bs) do
      {backend_mod, bs}
    else
      {:error, reason} ->
        Logger.warning("Failed to update access metadata: #{inspect(reason)}")
        {backend_mod, backend_state}
    end
  end

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

  defp model_context(state, operation, source_id \\ nil) do
    %Context{
      repo_id: state.repo_id,
      labels: state.telemetry_labels,
      operation: operation,
      source_id: source_id
    }
  end

  defp augment_query_with_context(nil, query), do: query

  defp augment_query_with_context(%{goal: goal, recent_steps: steps}, query)
       when is_binary(goal) and is_list(steps) do
    recent_steps =
      steps
      |> Enum.map(fn %{observation: observation, action: action}
                     when is_binary(observation) and is_binary(action) ->
        "- #{observation} -> #{action}"
      end)
      |> Enum.take(-3)

    case recent_steps do
      [] -> "Goal: #{goal}\n\nQuery: #{query}"
      steps -> "Goal: #{goal}\nRecent context:\n#{Enum.join(steps, "\n")}\n\nQuery: #{query}"
    end
  end
end
