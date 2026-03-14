defmodule Mnemosyne.MemoryStore do
  @moduledoc """
  GenServer owning the graph backend state.

  Retrieval and reasoning operations are spawned under a TaskSupervisor
  to avoid blocking the GenServer during LLM calls.
  """
  use GenServer

  require Logger

  alias Mnemosyne.Errors.Framework.PipelineError
  alias Mnemosyne.Graph
  alias Mnemosyne.Pipeline.Decay
  alias Mnemosyne.Pipeline.IntentMerger
  alias Mnemosyne.Pipeline.Reasoning
  alias Mnemosyne.Pipeline.Retrieval
  alias Mnemosyne.Pipeline.SemanticConsolidator

  # -- Client API --

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Applies a changeset to the graph via the backend."
  @spec apply_changeset(GenServer.server(), Graph.Changeset.t()) ::
          :ok | {:error, term()}
  def apply_changeset(server, changeset) do
    GenServer.call(server, {:apply_changeset, changeset})
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
  @spec delete_nodes(GenServer.server(), [String.t()]) ::
          :ok | {:error, term()}
  def delete_nodes(server, node_ids) do
    GenServer.call(server, {:delete_nodes, node_ids})
  end

  @doc "Consolidates near-duplicate semantic nodes."
  @spec consolidate_semantics(GenServer.server(), keyword()) ::
          {:ok, %{deleted: non_neg_integer(), checked: non_neg_integer()}}
          | {:error, term()}
  def consolidate_semantics(server, opts \\ []) do
    GenServer.call(server, {:consolidate_semantics, opts}, :timer.seconds(120))
  end

  @doc "Prunes low-utility nodes via decay scoring."
  @spec decay_nodes(GenServer.server(), keyword()) ::
          {:ok, %{deleted: non_neg_integer(), checked: non_neg_integer()}}
          | {:error, term()}
  def decay_nodes(server, opts \\ []) do
    GenServer.call(server, {:decay_nodes, opts}, :timer.seconds(120))
  end

  @doc "Returns the config, llm, and embedding modules for session creation."
  @spec get_session_defaults(GenServer.server()) :: %{
          config: term(),
          llm: module(),
          embedding: module()
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
          backend: {backend_mod, backend_state},
          config: Keyword.fetch!(opts, :config),
          llm: Keyword.fetch!(opts, :llm),
          embedding: Keyword.fetch!(opts, :embedding),
          task_supervisor: Keyword.fetch!(opts, :task_supervisor),
          pending_recalls: %{}
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:apply_changeset, changeset}, _from, state) do
    {backend_mod, backend_state} = state.backend

    merge_opts = [
      backend: state.backend,
      llm: state.llm,
      embedding: state.embedding,
      config: state.config,
      value_function: state.config.value_function
    ]

    with {:ok, merged_cs} <- IntentMerger.merge(changeset, merge_opts),
         {:ok, new_bs} <- backend_mod.apply_changeset(merged_cs, backend_state),
         {:ok, final_bs} <- maybe_update_metadata(backend_mod, merged_cs.metadata, new_bs) do
      {:reply, :ok, %{state | backend: {backend_mod, final_bs}}}
    else
      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:get_graph, _from, state) do
    {_backend_mod, backend_state} = state.backend
    {:reply, Map.get(backend_state, :graph, Graph.new()), state}
  end

  @impl true
  def handle_call(:get_session_defaults, _from, state) do
    defaults = %{config: state.config, llm: state.llm, embedding: state.embedding}
    {:reply, defaults, state}
  end

  @impl true
  def handle_call({:recall, query, opts}, from, state) do
    task = spawn_recall_task(state, query, opts)
    pending = Map.put(state.pending_recalls, task.ref, from)
    {:noreply, %{state | pending_recalls: pending}}
  end

  @impl true
  def handle_call({:recall_in_context, session_id, query, opts}, from, state) do
    augmented_query = augment_query_with_context(session_id, query)
    task = spawn_recall_task(state, augmented_query, opts)
    pending = Map.put(state.pending_recalls, task.ref, from)
    {:noreply, %{state | pending_recalls: pending}}
  end

  @impl true
  def handle_call({:consolidate_semantics, opts}, _from, state) do
    consolidation_opts =
      Keyword.merge(opts, backend: state.backend, config: state.config)

    case SemanticConsolidator.consolidate(consolidation_opts) do
      {:ok, result, updated_backend} ->
        {:reply, {:ok, result}, %{state | backend: updated_backend}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:decay_nodes, opts}, _from, state) do
    decay_opts =
      Keyword.merge(opts, backend: state.backend, config: state.config)

    case Decay.decay(decay_opts) do
      {:ok, result, updated_backend} ->
        {:reply, {:ok, result}, %{state | backend: updated_backend}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:delete_nodes, node_ids}, _from, state) do
    {backend_mod, backend_state} = state.backend

    case backend_mod.delete_nodes(node_ids, backend_state) do
      {:ok, new_bs} ->
        {:reply, :ok, %{state | backend: {backend_mod, new_bs}}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.pending_recalls, ref) do
      {nil, _} ->
        {:noreply, state}

      {from, pending} ->
        Process.demonitor(ref, [:flush])
        GenServer.reply(from, result)
        {:noreply, %{state | pending_recalls: pending}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.pending_recalls, ref) do
      {nil, _} ->
        {:noreply, state}

      {from, pending} ->
        GenServer.reply(from, {:error, PipelineError.exception(reason: {:task_crashed, reason})})
        {:noreply, %{state | pending_recalls: pending}}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private --

  defp spawn_recall_task(state, query, opts) do
    config = state.config
    llm = state.llm
    embedding = state.embedding
    value_fn = config.value_function
    max_hops = Keyword.get(opts, :max_hops, 2)
    backend = state.backend

    Task.Supervisor.async_nolink(state.task_supervisor, fn ->
      retrieval_opts = [
        llm: llm,
        embedding: embedding,
        backend: backend,
        value_function: value_fn,
        config: config,
        max_hops: max_hops
      ]

      with {:ok, result} <- Retrieval.retrieve(query, retrieval_opts) do
        Reasoning.reason(result, llm: llm, query: query, config: config)
      end
    end)
  end

  defp maybe_update_metadata(_backend_mod, metadata, bs) when map_size(metadata) == 0,
    do: {:ok, bs}

  defp maybe_update_metadata(backend_mod, metadata, bs),
    do: backend_mod.update_metadata(metadata, bs)

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
