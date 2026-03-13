defmodule Mnemosyne.MemoryStore do
  @moduledoc """
  GenServer owning the knowledge graph and storage state.

  Loads the graph from storage on init via `handle_continue`.
  Retrieval and reasoning operations are spawned under a TaskSupervisor
  to avoid blocking the GenServer during LLM calls.
  """
  use GenServer

  require Logger

  alias Mnemosyne.Graph
  alias Mnemosyne.Pipeline.Reasoning
  alias Mnemosyne.Pipeline.Retrieval

  @default_value_functions %{
    episodic: Mnemosyne.ValueFunctions.EpisodicRelevant,
    semantic: Mnemosyne.ValueFunctions.SemanticRelevant,
    procedural: Mnemosyne.ValueFunctions.ProceduralEqual,
    subgoal: Mnemosyne.ValueFunctions.SubgoalMatch,
    tag: Mnemosyne.ValueFunctions.TagExact,
    source: Mnemosyne.ValueFunctions.SourceLinked
  }

  # -- Client API --

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Applies a changeset to the graph and persists it to storage."
  @spec apply_changeset(GenServer.server(), Graph.Changeset.t()) :: :ok | {:error, term()}
  def apply_changeset(server, changeset) do
    GenServer.call(server, {:apply_changeset, changeset})
  end

  @doc "Returns the current graph."
  @spec get_graph(GenServer.server()) :: Graph.t()
  def get_graph(server) do
    GenServer.call(server, :get_graph)
  end

  @doc "Runs async retrieval + reasoning and returns the result."
  @spec recall(GenServer.server(), String.t(), keyword()) ::
          {:ok, Reasoning.ReasonedMemory.t()} | {:error, term()}
  def recall(server, query, opts \\ []) do
    GenServer.call(server, {:recall, query, opts}, :timer.seconds(120))
  end

  @doc "Fetches session context, augments the query, then runs recall."
  @spec recall_in_context(GenServer.server(), term(), String.t(), keyword()) ::
          {:ok, Reasoning.ReasonedMemory.t()} | {:error, term()}
  def recall_in_context(server, session_id, query, opts \\ []) do
    GenServer.call(server, {:recall_in_context, session_id, query, opts}, :timer.seconds(120))
  end

  @doc "Removes nodes from the graph and storage."
  @spec delete_nodes(GenServer.server(), [String.t()]) :: :ok | {:error, term()}
  def delete_nodes(server, node_ids) do
    GenServer.call(server, {:delete_nodes, node_ids})
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
    {storage_mod, storage_opts} = Keyword.fetch!(opts, :storage)

    case storage_mod.init(storage_opts) do
      {:ok, storage_state} ->
        state = %{
          graph: Graph.new(),
          storage: {storage_mod, storage_state},
          config: Keyword.fetch!(opts, :config),
          llm: Keyword.fetch!(opts, :llm),
          embedding: Keyword.fetch!(opts, :embedding),
          value_functions: Keyword.get(opts, :value_functions, @default_value_functions),
          task_supervisor: Keyword.fetch!(opts, :task_supervisor),
          pending_recalls: %{}
        }

        {:ok, state, {:continue, :load_graph}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:load_graph, state) do
    {storage_mod, storage_state} = state.storage

    result =
      Mnemosyne.Telemetry.span([:storage, :load], %{backend: storage_mod}, fn ->
        case storage_mod.load_graph(storage_state) do
          {:ok, graph} -> {{:ok, graph}, %{}}
          {:error, _} = error -> {error, %{}}
        end
      end)

    case result do
      {:ok, graph} -> {:noreply, %{state | graph: graph}}
      {:error, _} -> {:noreply, state}
    end
  end

  @impl true
  def handle_call({:apply_changeset, changeset}, _from, state) do
    {storage_mod, storage_state} = state.storage

    result =
      Mnemosyne.Telemetry.span([:storage, :persist], %{backend: storage_mod}, fn ->
        case storage_mod.persist_changeset(changeset, storage_state) do
          :ok -> {:ok, %{}}
          {:error, _} = error -> {error, %{}}
        end
      end)

    case result do
      :ok ->
        graph = Graph.apply_changeset(state.graph, changeset)
        {:reply, :ok, %{state | graph: graph}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:get_graph, _from, state) do
    {:reply, state.graph, state}
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
  def handle_call({:delete_nodes, node_ids}, _from, state) do
    {storage_mod, storage_state} = state.storage

    case storage_mod.delete_nodes(node_ids, storage_state) do
      :ok ->
        graph = Enum.reduce(node_ids, state.graph, &Graph.delete_node(&2, &1))
        {:reply, :ok, %{state | graph: graph}}

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
        GenServer.reply(from, {:error, {:task_crashed, reason}})
        {:noreply, %{state | pending_recalls: pending}}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private --

  defp spawn_recall_task(state, query, opts) do
    graph = state.graph
    config = state.config
    llm = state.llm
    embedding = state.embedding
    value_fns = state.value_functions
    max_hops = Keyword.get(opts, :max_hops, 2)

    Task.Supervisor.async_nolink(state.task_supervisor, fn ->
      retrieval_opts = [
        llm: llm,
        embedding: embedding,
        graph: graph,
        value_functions: value_fns,
        config: config,
        max_hops: max_hops
      ]

      with {:ok, result} <- Retrieval.retrieve(query, retrieval_opts) do
        Reasoning.reason(result, llm: llm, query: query, config: config)
      end
    end)
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
