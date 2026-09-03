defmodule Mnemosyne do
  @moduledoc """
  Agentic memory library that models memory as a knowledge graph using
  reinforcement-learning primitives (episodes, trajectories, rewards, value functions).

  ## Architecture

  Mnemosyne is organized in three layers:

    1. **Data Primitives** - An in-memory knowledge graph with typed nodes
       (`Episodic`, `Semantic`, `Procedural`, `Subgoal`, `Source`, `Tag`)
       connected by directed links. Mutations happen through `Changeset` structs.

    2. **Pipeline** - LLM-driven extraction that turns raw observation-action
       sequences into structured knowledge. Episodes track steps, detect
       trajectory boundaries via embedding similarity, and produce changesets
       that grow the graph.

    3. **Retrieval** - Value-function-scored retrieval over the graph, combining
       multiple node types to produce contextually relevant memory results.

  ## Repositories

  All graph operations are scoped to a **repository**. A repository is an
  isolated graph backend with its own MemoryStore process. Open a repo via
  `open_repo/2`, then pass its `repo_id` as the first argument to all
  operations.

      {:ok, _pid} = Mnemosyne.open_repo("my-repo", backend: {InMemory, persistence: {DETS, path: "repo.dets"}})

  ## Write Path (Ingestion)

  Complete caller-owned trajectories are stored through the blocking ingestion API.
  Success means the resulting graph nodes are visible.

      trajectory = %Mnemosyne.Trajectory{
        source_id: "task-42",
        goal: "Learn Elixir patterns",
        steps: [
          %{observation: "Read about GenServer", action: "Implemented a cache"}
        ]
      }

      {:ok, receipt} = Mnemosyne.ingest("my-repo", trajectory)

  ## Read Path (Recall)

  Recall queries the knowledge graph using value functions to score and rank
  nodes by relevance. Caller-provided task context can augment queries without
  being persisted.

      {:ok, memories} = Mnemosyne.recall("my-repo", "How to implement caching?")

  ## Graph Management

  Direct graph operations for inspection and bulk mutations:

      graph = Mnemosyne.get_graph("my-repo")
      :ok = Mnemosyne.apply_changeset("my-repo", changeset)
      :ok = Mnemosyne.delete_nodes("my-repo", ["node-1", "node-2"])

  ## Supervision

  Mnemosyne runs under its own supervision tree (`Mnemosyne.Supervisor`).
  Multiple independent instances can coexist by passing a custom `:supervisor`
  name in opts. Each supervisor owns its own RepoRegistry, TaskSupervisor,
  and RepoSupervisor.
  """

  alias Mnemosyne.Errors.Framework.NotFoundError
  alias Mnemosyne.Errors.Framework.RepoError
  alias Mnemosyne.IngestionReceipt
  alias Mnemosyne.MemoryStore
  alias Mnemosyne.Pipeline.RecallResult
  alias Mnemosyne.Supervisor, as: MneSupervisor
  alias Mnemosyne.Trajectory

  @default_sup Mnemosyne.Supervisor

  # -- Repo Lifecycle --

  @doc """
  Opens a new memory repository under the supervision tree.

  Starts a `MemoryStore` process registered in the `RepoRegistry` with the
  given `repo_id`. Each repo has its own isolated graph backend.

  ## Options

    * `:backend` - Required. A `{module, opts}` tuple for the graph backend.
    * `:supervisor` - Name of the Mnemosyne supervisor. Defaults to `Mnemosyne.Supervisor`.
    * `:config` - A `Mnemosyne.Config` struct overriding shared defaults.
    * `:llm` - LLM adapter module overriding shared defaults.
    * `:embedding` - Embedding adapter module overriding shared defaults.
    * `:telemetry_labels` - Flat map of string or atom keys to string, atom,
      number, or boolean values. Defaults to `%{}` and applies only while the
      repository is open.
  """
  @spec open_repo(String.t(), keyword()) :: {:ok, pid()} | {:error, Mnemosyne.Errors.error()}
  def open_repo(repo_id, opts \\ []) do
    telemetry_labels = Keyword.get(opts, :telemetry_labels, %{})

    if valid_telemetry_labels?(telemetry_labels) do
      start_repo(repo_id, opts, telemetry_labels)
    else
      {:error, RepoError.exception(repo_id: repo_id, reason: :invalid_telemetry_labels)}
    end
  end

  defp start_repo(repo_id, opts, telemetry_labels) do
    sup_name = Keyword.get(opts, :supervisor, @default_sup)
    defaults = MneSupervisor.get_defaults(sup_name)
    repo_sup = MneSupervisor.repo_supervisor_name(sup_name)
    repo_registry = MneSupervisor.repo_registry_name(sup_name)
    task_sup = MneSupervisor.task_supervisor_name(sup_name)

    via = {:via, Registry, {repo_registry, repo_id}}

    store_opts = [
      name: via,
      repo_id: repo_id,
      telemetry_labels: telemetry_labels,
      backend: Keyword.get(opts, :backend, defaults.backend),
      config: Keyword.get(opts, :config, defaults.config),
      llm: Keyword.get(opts, :llm, defaults.llm),
      embedding: Keyword.get(opts, :embedding, defaults.embedding),
      notifier: Keyword.get(opts, :notifier, defaults.notifier),
      task_supervisor: task_sup
    ]

    Mnemosyne.Telemetry.span([:repo, :open], %{repo_id: repo_id}, fn ->
      case DynamicSupervisor.start_child(repo_sup, {MemoryStore, store_opts}) do
        {:ok, pid} ->
          {{:ok, pid}, %{}}

        {:error, {:already_started, _}} ->
          {{:error, RepoError.exception(repo_id: repo_id, reason: :already_open)}, %{}}

        {:error, reason} ->
          {{:error, RepoError.exception(repo_id: repo_id, reason: reason)}, %{}}
      end
    end)
  end

  defp valid_telemetry_labels?(labels) when is_struct(labels), do: false

  defp valid_telemetry_labels?(labels) when is_map(labels) do
    Enum.all?(labels, fn {key, value} ->
      (is_binary(key) or is_atom(key)) and
        (is_binary(value) or is_atom(value) or is_number(value) or is_boolean(value))
    end)
  end

  defp valid_telemetry_labels?(_labels), do: false

  @doc """
  Closes a running memory repository.

  Terminates the `MemoryStore` process for the given `repo_id`.

  ## Options

    * `:supervisor` - Name of the Mnemosyne supervisor. Defaults to `Mnemosyne.Supervisor`.
  """
  @spec close_repo(String.t(), keyword()) :: :ok | {:error, NotFoundError.t()}
  def close_repo(repo_id, opts \\ []) do
    sup_name = Keyword.get(opts, :supervisor, @default_sup)
    repo_sup = MneSupervisor.repo_supervisor_name(sup_name)

    Mnemosyne.Telemetry.span([:repo, :close], %{repo_id: repo_id}, fn ->
      case lookup_repo(repo_id, opts) do
        {:ok, pid} ->
          {DynamicSupervisor.terminate_child(repo_sup, pid), %{}}

        {:error, _} = error ->
          {error, %{}}
      end
    end)
  end

  @doc """
  Lists all currently open repository IDs.

  ## Options

    * `:supervisor` - Name of the Mnemosyne supervisor. Defaults to `Mnemosyne.Supervisor`.
  """
  @spec list_repos(keyword()) :: [String.t()]
  def list_repos(opts \\ []) do
    sup_name = Keyword.get(opts, :supervisor, @default_sup)
    repo_registry = MneSupervisor.repo_registry_name(sup_name)

    Registry.select(repo_registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  # -- Repo-scoped Operations --

  @doc """
  Stores a complete trajectory in a repository.

  Returns only after the trajectory is committed and its graph nodes are visible.
  Repeating the same payload with the same source ID returns the original receipt;
  a different payload for that source ID returns an ingestion error.

  ## Options

    * `:supervisor` - Name of the Mnemosyne supervisor. Defaults to `Mnemosyne.Supervisor`.
    * `:config` - A `Mnemosyne.Config` struct overriding the repo default for this ingestion.
    * `:llm` - LLM adapter module overriding the repo default for this ingestion.
    * `:embedding` - Embedding adapter module overriding the repo default for this ingestion.

  `:llm_opts` is passed through ingestion LLM stages where used. Per-call
  `:embedding_opts` currently applies only to write-time intent merging; ordinary
  trajectory embedding calls use the selected config's embedding options.
  """
  @spec ingest(String.t(), Trajectory.t(), keyword()) ::
          {:ok, IngestionReceipt.t()} | {:error, Mnemosyne.Errors.error()}
  def ingest(repo_id, %Trajectory{source_id: source_id} = trajectory, opts \\ []) do
    metadata = %{repo_id: repo_id, source_id: source_id}
    execution_opts = Keyword.delete(opts, :supervisor)

    Mnemosyne.Telemetry.span([:ingestion, :ingest], metadata, fn ->
      case lookup_repo(repo_id, opts) do
        {:ok, pid} ->
          result = MemoryStore.ingest(pid, trajectory, execution_opts)
          {result, ingestion_measurements(result)}

        {:error, _} = error ->
          {error, %{}}
      end
    end)
  end

  defp ingestion_measurements({:ok, %IngestionReceipt{node_ids: node_ids}}),
    do: %{node_count: length(node_ids)}

  defp ingestion_measurements({:error, _}), do: %{}

  @doc """
  Retrieves relevant memories from the knowledge graph for the given query.

  Runs the retrieval pipeline, which computes embeddings for the query and
  scores candidate nodes using value functions across all node types
  (episodic, semantic, procedural, subgoal, tag, source). Results are
  ranked and filtered by relevance.

  ## Options

    * `:supervisor` - Name of the Mnemosyne supervisor. Defaults to `Mnemosyne.Supervisor`.
      This option is used only to locate the repository.
    * `:context` - Transient active-task context shaped as
      `%{goal: goal, recent_steps: [%{observation: observation, action: action}]}`.
      The goal and last three recent steps augment the query without being persisted.
    * `:source_id` - Optional correlation identifier included in recall traces,
      notifier metadata, and pipeline telemetry. It does not augment the query.

  ## Examples

      {:ok, memories} = Mnemosyne.recall("my-repo", "How to handle GenServer timeouts?")

      {:ok, memories} =
        Mnemosyne.recall("my-repo", "What should I try next?",
          source_id: "task-42",
          context: %{
            goal: "Diagnose intermittent timeouts",
            recent_steps: [
              %{observation: "Request timed out", action: "Inspected application logs"}
            ]
          }
        )
  """
  @spec recall(String.t(), String.t(), keyword()) ::
          {:ok, RecallResult.t()} | {:error, Mnemosyne.Errors.error()}
  def recall(repo_id, query, opts \\ []) do
    with {:ok, pid} <- lookup_repo(repo_id, opts) do
      MemoryStore.recall(pid, query, Keyword.delete(opts, :supervisor))
    end
  end

  @doc """
  Returns the current knowledge graph held by the repo's MemoryStore.

  The graph contains all committed nodes and their links. Useful for
  inspection, debugging, or building custom retrieval strategies.
  """
  @spec get_graph(String.t(), keyword()) :: Mnemosyne.Graph.t() | {:error, NotFoundError.t()}
  def get_graph(repo_id, opts \\ []) do
    with {:ok, pid} <- lookup_repo(repo_id, opts) do
      MemoryStore.get_graph(pid)
    end
  end

  @doc "Fetches a single node by ID from the repo's graph."
  @spec get_node(String.t(), String.t(), keyword()) :: {:ok, struct() | nil} | {:error, term()}
  def get_node(repo_id, node_id, opts \\ []) do
    with {:ok, pid} <- lookup_repo(repo_id, opts) do
      MemoryStore.get_node(pid, node_id)
    end
  end

  @doc "Fetches all nodes of the given types from the repo's graph."
  @spec get_nodes_by_type(String.t(), [atom()], keyword()) :: {:ok, [struct()]} | {:error, term()}
  def get_nodes_by_type(repo_id, types, opts \\ []) do
    with {:ok, pid} <- lookup_repo(repo_id, opts) do
      MemoryStore.get_nodes_by_type(pid, types)
    end
  end

  @doc "Fetches metadata for the given node IDs."
  @spec get_metadata(String.t(), [String.t()], keyword()) ::
          {:ok, %{String.t() => Mnemosyne.NodeMetadata.t()}} | {:error, term()}
  def get_metadata(repo_id, node_ids, opts \\ []) do
    with {:ok, pid} <- lookup_repo(repo_id, opts) do
      MemoryStore.get_metadata(pid, node_ids)
    end
  end

  @doc "Fetches nodes linked to the given node IDs."
  @spec get_linked_nodes(String.t(), [String.t()], keyword()) ::
          {:ok, [struct()]} | {:error, term()}
  def get_linked_nodes(repo_id, node_ids, opts \\ []) do
    with {:ok, pid} <- lookup_repo(repo_id, opts) do
      MemoryStore.get_linked_nodes(pid, node_ids)
    end
  end

  @doc """
  Fetches the most recently created memories from the repo, sorted newest first.

  Returns up to `top_k` nodes paired with their metadata. By default fetches
  semantic and procedural nodes.

  ## Options

    * `:types` - Node types to fetch. Defaults to `[:semantic, :procedural]`.
    * `:supervisor` - Name of the Mnemosyne supervisor. Defaults to `Mnemosyne.Supervisor`.

  ## Examples

      {:ok, memories} = Mnemosyne.latest("my-repo", 10)
      {:ok, memories} = Mnemosyne.latest("my-repo", 5, types: [:semantic])
  """
  @spec latest(String.t(), pos_integer(), keyword()) ::
          {:ok, [{struct(), Mnemosyne.NodeMetadata.t()}]} | {:error, term()}
  def latest(repo_id, top_k, opts \\ []) do
    with {:ok, pid} <- lookup_repo(repo_id, opts) do
      MemoryStore.latest(pid, top_k, opts)
    end
  end

  @doc """
  Applies a changeset to the knowledge graph asynchronously.

  Enqueues the changeset for application via the MemoryStore write lane.
  Returns immediately; the actual mutation happens in the background.
  Subscribe to Notifier events (`:changeset_applied`) to observe completion.
  """
  @spec apply_changeset(String.t(), Mnemosyne.Graph.Changeset.t(), keyword()) ::
          :ok | {:error, NotFoundError.t()}
  def apply_changeset(repo_id, changeset, opts \\ []) do
    with {:ok, pid} <- lookup_repo(repo_id, opts) do
      MemoryStore.apply_changeset(pid, changeset)
    end
  end

  @doc """
  Deletes nodes from the knowledge graph by their IDs asynchronously.

  Enqueues the deletion via the MemoryStore write lane. Returns immediately;
  the actual removal happens in the background. Subscribe to Notifier events
  (`:nodes_deleted`) to observe completion.
  """
  @spec delete_nodes(String.t(), [String.t()], keyword()) ::
          :ok | {:error, NotFoundError.t()}
  def delete_nodes(repo_id, node_ids, opts \\ []) do
    with {:ok, pid} <- lookup_repo(repo_id, opts) do
      MemoryStore.delete_nodes(pid, node_ids)
    end
  end

  @doc """
  Consolidates near-duplicate semantic nodes in the repo's graph asynchronously.

  Discovers semantically similar nodes via tag-neighbor similarity and merges
  each pair through an LLM-synthesized statement: the higher-scored node
  survives with the merged proposition while the other's links and metadata
  transfer to it. Weakly related pairs are kept separate. Returns immediately;
  the consolidation runs in the background. Subscribe to Notifier events
  (`:consolidation_completed`) to observe results.

  ## Options

    * `:supervisor` - Name of the Mnemosyne supervisor. Defaults to `Mnemosyne.Supervisor`.
  """
  @spec consolidate_semantics(String.t(), keyword()) ::
          :ok | {:error, NotFoundError.t()}
  def consolidate_semantics(repo_id, opts \\ []) do
    with {:ok, pid} <- lookup_repo(repo_id, opts) do
      MemoryStore.consolidate_semantics(pid, opts)
    end
  end

  @doc """
  Prunes low-utility nodes from the repo's graph via decay scoring asynchronously.

  Scores nodes on recency, frequency, and reward signals and removes those
  below the threshold. Cleans up orphaned Tags/Intents after deletion. Returns
  immediately; pruning runs in the background. Subscribe to Notifier events
  (`:decay_completed`) to observe results.

  ## Options

    * `:supervisor` - Name of the Mnemosyne supervisor. Defaults to `Mnemosyne.Supervisor`.
  """
  @spec decay_nodes(String.t(), keyword()) ::
          :ok | {:error, NotFoundError.t()}
  def decay_nodes(repo_id, opts \\ []) do
    with {:ok, pid} <- lookup_repo(repo_id, opts) do
      MemoryStore.decay_nodes(pid, opts)
    end
  end

  @doc """
  Strips dangling link references and removes orphaned tags/intents from
  the repo's graph asynchronously.

  Use this after upgrading from a release whose persistence layer left
  back-references behind on delete, or any time the graph is suspected to
  carry stale link IDs. Returns immediately; repair runs in the background.
  Subscribe to Notifier events (`:repair_completed`) to observe results.

  ## Options

    * `:supervisor` - Name of the Mnemosyne supervisor. Defaults to `Mnemosyne.Supervisor`.
  """
  @spec repair_graph(String.t(), keyword()) ::
          :ok | {:error, NotFoundError.t()}
  def repair_graph(repo_id, opts \\ []) do
    with {:ok, pid} <- lookup_repo(repo_id, opts) do
      MemoryStore.repair_graph(pid, opts)
    end
  end

  @doc """
  Validates episodic grounding of abstract nodes in the repo's graph asynchronously.

  Walks provenance chains from semantic/procedural nodes to source nodes
  and penalizes nodes whose source embeddings diverge from the abstract
  node's embedding. Returns immediately; validation runs in the background.
  """
  @spec validate_episodic(String.t(), keyword()) ::
          :ok | {:error, NotFoundError.t()}
  def validate_episodic(repo_id, opts \\ []) do
    with {:ok, pid} <- lookup_repo(repo_id, opts) do
      MemoryStore.validate_episodic(pid, opts)
    end
  end

  # -- Private --

  defp lookup_repo(repo_id, opts) do
    sup_name = Keyword.get(opts, :supervisor, @default_sup)
    repo_registry = MneSupervisor.repo_registry_name(sup_name)

    case Registry.lookup(repo_registry, repo_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, NotFoundError.exception(resource: :repo, id: repo_id)}
    end
  end
end
