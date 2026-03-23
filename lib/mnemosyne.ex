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

  ## Write Path (Sessions)

  Sessions are the write interface to the knowledge graph. A session is tied
  to a specific repo and collects observation-action pairs, groups them into
  trajectories, and uses LLM calls to extract semantic and procedural knowledge.

      {:ok, session_id} = Mnemosyne.start_session("Learn Elixir patterns", repo: "my-repo")
      :ok = Mnemosyne.append(session_id, "Read about GenServer", "Implemented a cache")
      :ok = Mnemosyne.append(session_id, "Cache worked well", "Added TTL support")
      :ok = Mnemosyne.close_and_commit(session_id)

  Sessions follow a state machine lifecycle:
  `:idle` -> `:collecting` -> `:extracting` -> `:ready` -> (committed/discarded)

  The `:extracting` state runs asynchronously under a `Task.Supervisor`, keeping
  the session process responsive. If extraction fails, the session moves to
  `:failed` and preserves the episode for retry.

  ## Read Path (Recall)

  Recall queries the knowledge graph using value functions to score and rank
  nodes by relevance. Session context can augment queries with the current
  episode's state for more targeted retrieval.

      {:ok, memories} = Mnemosyne.recall("my-repo", "How to implement caching?")
      {:ok, memories} = Mnemosyne.recall_in_context("my-repo", session_id, "What did I try before?")

  ## Graph Management

  Direct graph operations for inspection and bulk mutations:

      graph = Mnemosyne.get_graph("my-repo")
      :ok = Mnemosyne.apply_changeset("my-repo", changeset)
      :ok = Mnemosyne.delete_nodes("my-repo", ["node-1", "node-2"])

  ## Supervision

  Mnemosyne runs under its own supervision tree (`Mnemosyne.Supervisor`).
  Multiple independent instances can coexist by passing a custom `:supervisor`
  name in opts. Each supervisor owns its own Registry, RepoRegistry,
  TaskSupervisor, RepoSupervisor, and SessionSupervisor.
  """

  alias Mnemosyne.Errors.Framework.NotFoundError
  alias Mnemosyne.Errors.Framework.PipelineError
  alias Mnemosyne.Errors.Framework.RepoError
  alias Mnemosyne.MemoryStore
  alias Mnemosyne.Pipeline.RecallResult
  alias Mnemosyne.Session
  alias Mnemosyne.Supervisor, as: MneSupervisor

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
  """
  @spec open_repo(String.t(), keyword()) :: {:ok, pid()} | {:error, Mnemosyne.Errors.error()}
  def open_repo(repo_id, opts \\ []) do
    sup_name = Keyword.get(opts, :supervisor, @default_sup)
    defaults = MneSupervisor.get_defaults(sup_name)
    repo_sup = MneSupervisor.repo_supervisor_name(sup_name)
    repo_registry = MneSupervisor.repo_registry_name(sup_name)
    task_sup = MneSupervisor.task_supervisor_name(sup_name)

    via = {:via, Registry, {repo_registry, repo_id}}

    store_opts = [
      name: via,
      repo_id: repo_id,
      backend: Keyword.fetch!(opts, :backend),
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

  # -- Sessions --

  @doc """
  Starts a new memory session with the given goal.

  Creates a new `Session` process under the `SessionSupervisor` and immediately
  opens an episode with the provided goal. The session begins in the `:collecting`
  state, ready to receive observation-action pairs via `append/4`.

  LLM, embedding, and config defaults are pulled from the repo's `MemoryStore`
  unless explicitly overridden in `opts`.

  ## Options

    * `:repo` - Required. The repo ID to bind this session to.
    * `:supervisor` - Name of the Mnemosyne supervisor to use. Defaults to `Mnemosyne.Supervisor`.
    * `:config` - A `Mnemosyne.Config` struct overriding the stored defaults.
    * `:llm` - LLM adapter module overriding the stored default.
    * `:embedding` - Embedding adapter module overriding the stored default.

  ## Examples

      {:ok, session_id} = Mnemosyne.start_session("Explore caching strategies", repo: "my-repo")
  """
  @spec start_session(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def start_session(goal, opts \\ []) do
    sup_name = Keyword.get(opts, :supervisor, @default_sup)
    repo_id = Keyword.fetch!(opts, :repo)
    registry = MneSupervisor.registry_name(sup_name)
    task_sup = MneSupervisor.task_supervisor_name(sup_name)
    session_sup = MneSupervisor.session_supervisor_name(sup_name)

    with {:ok, store_pid} <- lookup_repo(repo_id, opts) do
      defaults = MemoryStore.get_session_defaults(store_pid)

      session_opts = [
        registry: registry,
        task_supervisor: task_sup,
        memory_store: store_pid,
        repo_id: repo_id,
        config: Keyword.get(opts, :config, defaults.config),
        llm: Keyword.get(opts, :llm, defaults.llm),
        embedding: Keyword.get(opts, :embedding, defaults.embedding),
        notifier: Keyword.get(opts, :notifier, defaults.notifier)
      ]

      case DynamicSupervisor.start_child(session_sup, {Session, session_opts}) do
        {:ok, pid} ->
          session_id = Session.id(pid)
          :ok = Session.start_episode(pid, goal)
          {:ok, session_id}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Appends an observation-action pair to the current episode.

  The observation describes what the agent perceived and the action describes
  what the agent did in response. Each pair becomes a step in the current
  trajectory. When the embedding similarity between consecutive observations
  drops below the threshold (0.75), a new trajectory boundary is detected
  automatically.

  The session must be in the `:collecting` state.

  ## Options

    * `:supervisor` - Name of the Mnemosyne supervisor. Defaults to `Mnemosyne.Supervisor`.
  """
  @spec append(String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, Mnemosyne.Errors.error()}
  def append(session_id, observation, action, opts \\ []) do
    with {:ok, pid} <- lookup_session(session_id, opts) do
      Session.append(pid, observation, action)
    end
  end

  @doc """
  Like `append/4` but returns immediately. Accepts an optional callback that
  receives `:ok` or `{:error, reason}` when the append finishes.

  ## Options

    * `:supervisor` - Name of the Mnemosyne supervisor. Defaults to `Mnemosyne.Supervisor`.
  """
  @spec append_async(
          String.t(),
          String.t(),
          String.t(),
          (Session.append_result() -> any()) | nil,
          keyword()
        ) ::
          :ok | {:error, Mnemosyne.Errors.error()}
  def append_async(session_id, observation, action, callback \\ nil, opts \\ []) do
    with {:ok, pid} <- lookup_session(session_id, opts) do
      Session.append_async(pid, observation, action, callback)
    end
  end

  @doc """
  Closes the current episode, triggering asynchronous knowledge extraction.

  Moves the session from `:collecting` to `:extracting`. The extraction
  pipeline runs in a supervised task and processes each trajectory to extract
  semantic facts, procedural instructions, and compute returns. Once
  extraction completes, the session transitions to `:ready` (success)
  or `:failed` (extraction error).

  Use `commit/2` after extraction completes to persist the results, or
  `close_and_commit/2` to do both in one call.
  """
  @spec close(String.t(), keyword()) :: :ok | {:error, Mnemosyne.Errors.error()}
  def close(session_id, opts \\ []) do
    with {:ok, pid} <- lookup_session(session_id, opts) do
      Session.close(pid)
    end
  end

  @doc """
  Commits the extracted changeset to the MemoryStore.

  Enqueues the knowledge graph changeset produced by the extraction pipeline
  for application to the repo's `MemoryStore`. The session must be in the
  `:ready` state. The changeset is applied asynchronously via the write lane;
  subscribe to Notifier events (`:changeset_applied`) to observe completion.

  After committing, the session transitions back to `:idle` and can start
  a new episode.
  """
  @spec commit(String.t(), keyword()) :: :ok | {:error, Mnemosyne.Errors.error()}
  def commit(session_id, opts \\ []) do
    with {:ok, pid} <- lookup_session(session_id, opts) do
      Session.commit(pid)
    end
  end

  @doc """
  Discards the extraction result without committing to the knowledge graph.

  Drops the changeset produced by extraction. Useful when the extracted
  knowledge is deemed low-quality or irrelevant. The session returns to
  `:idle` and can start a new episode.
  """
  @spec discard(String.t(), keyword()) :: :ok | {:error, Mnemosyne.Errors.error()}
  def discard(session_id, opts \\ []) do
    with {:ok, pid} <- lookup_session(session_id, opts) do
      Session.discard(pid)
    end
  end

  @doc """
  Like `commit/2` but returns immediately. When the session is busy
  (extracting or collecting with in-flight trajectory tasks), the commit
  is queued and executes when the blocking work completes.

  The optional callback receives `{:ok, :committed}` or `{:error, reason}`.
  An `:ok` return means the operation was accepted, not that it succeeded.

  ## Options

    * `:supervisor` - Name of the Mnemosyne supervisor. Defaults to `Mnemosyne.Supervisor`.
  """
  @spec commit_async(String.t(), Session.op_callback(), keyword()) ::
          :ok | {:error, Mnemosyne.Errors.error()}
  def commit_async(session_id, callback \\ nil, opts \\ []) do
    with {:ok, pid} <- lookup_session(session_id, opts) do
      Session.commit_async(pid, callback)
    end
  end

  @doc """
  Like `discard/2` but returns immediately with optional callback.
  See `commit_async/3` for queuing semantics.

  ## Options

    * `:supervisor` - Name of the Mnemosyne supervisor. Defaults to `Mnemosyne.Supervisor`.
  """
  @spec discard_async(String.t(), Session.op_callback(), keyword()) ::
          :ok | {:error, Mnemosyne.Errors.error()}
  def discard_async(session_id, callback \\ nil, opts \\ []) do
    with {:ok, pid} <- lookup_session(session_id, opts) do
      Session.discard_async(pid, callback)
    end
  end

  @doc """
  Like `start_session/2` but for resuming an existing idle session
  with a new episode. Returns immediately with optional callback.
  See `commit_async/3` for queuing semantics.

  ## Options

    * `:supervisor` - Name of the Mnemosyne supervisor. Defaults to `Mnemosyne.Supervisor`.
  """
  @spec start_episode_async(String.t(), String.t(), Session.op_callback(), keyword()) ::
          :ok | {:error, Mnemosyne.Errors.error()}
  def start_episode_async(session_id, goal, callback \\ nil, opts \\ []) do
    with {:ok, pid} <- lookup_session(session_id, opts) do
      Session.start_episode_async(pid, goal, callback)
    end
  end

  @doc """
  Like `close/2` but returns immediately with optional callback.
  See `commit_async/3` for queuing semantics.

  ## Options

    * `:supervisor` - Name of the Mnemosyne supervisor. Defaults to `Mnemosyne.Supervisor`.
  """
  @spec close_async(String.t(), Session.op_callback(), keyword()) ::
          :ok | {:error, Mnemosyne.Errors.error()}
  def close_async(session_id, callback \\ nil, opts \\ []) do
    with {:ok, pid} <- lookup_session(session_id, opts) do
      Session.close_async(pid, callback)
    end
  end

  @doc """
  Returns the current state of a session.

  Possible states: `:idle`, `:collecting`, `:extracting`, `:ready`, `:failed`.

  Returns `{:error, NotFoundError}` if the session ID is not registered.
  """
  @spec session_state(String.t(), keyword()) :: Session.state() | {:error, NotFoundError.t()}
  def session_state(session_id, opts \\ []) do
    with {:ok, pid} <- lookup_session(session_id, opts) do
      Session.state(pid)
    end
  end

  @doc """
  Closes the episode, waits for extraction to complete, and commits the result.

  Convenience function that combines `close/2`, polling for extraction completion,
  and `commit/2` into a single blocking call. Handles transient extraction failures
  by retrying up to `max_retries` times.

  ## Options

    * `:max_retries` - Number of retry attempts on transient extraction failures. Defaults to `2`.
    * `:max_polls` - Maximum number of polling iterations while waiting for extraction. Defaults to `200`.
    * `:poll_interval` - Milliseconds between polls. Defaults to `50`.
    * `:supervisor` - Name of the Mnemosyne supervisor. Defaults to `Mnemosyne.Supervisor`.

  ## Examples

      :ok = Mnemosyne.close_and_commit(session_id)

      :ok = Mnemosyne.close_and_commit(session_id, max_retries: 5, poll_interval: 100)
  """
  @spec close_and_commit(String.t(), keyword()) :: :ok | {:error, Mnemosyne.Errors.error()}
  def close_and_commit(session_id, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, 2)
    poll_opts = Keyword.take(opts, [:max_polls, :poll_interval])

    with {:ok, pid} <- lookup_session(session_id, opts),
         :ok <- Session.close(pid) do
      await_and_commit(pid, max_retries, poll_opts)
    end
  end

  # -- Repo-scoped Operations --

  @doc """
  Retrieves relevant memories from the knowledge graph for the given query.

  Runs the retrieval pipeline, which computes embeddings for the query and
  scores candidate nodes using value functions across all node types
  (episodic, semantic, procedural, subgoal, tag, source). Results are
  ranked and filtered by relevance.

  ## Options

    * `:supervisor` - Name of the Mnemosyne supervisor. Defaults to `Mnemosyne.Supervisor`.

  ## Examples

      {:ok, memories} = Mnemosyne.recall("my-repo", "How to handle GenServer timeouts?")
  """
  @spec recall(String.t(), String.t(), keyword()) ::
          {:ok, RecallResult.t()} | {:error, Mnemosyne.Errors.error()}
  def recall(repo_id, query, opts \\ []) do
    with {:ok, pid} <- lookup_repo(repo_id, opts) do
      MemoryStore.recall(pid, query, opts)
    end
  end

  @doc """
  Retrieves memories using both the query and the session's current context.

  Augments the query with the active episode's state (current subgoal,
  recent observations) to produce more contextually relevant results.
  If the session is not found, falls back to a plain `recall/3`.

  ## Examples

      {:ok, memories} = Mnemosyne.recall_in_context("my-repo", session_id, "What patterns apply here?")
  """
  @spec recall_in_context(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, RecallResult.t()} | {:error, Mnemosyne.Errors.error()}
  def recall_in_context(repo_id, session_id, query, opts \\ []) do
    with {:ok, pid} <- lookup_repo(repo_id, opts) do
      case lookup_session(session_id, opts) do
        {:ok, session_pid} ->
          MemoryStore.recall_in_context(
            pid,
            session_pid,
            query,
            Keyword.put(opts, :session_id, session_id)
          )

        {:error, %NotFoundError{}} ->
          MemoryStore.recall(pid, query, opts)
      end
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

  Discovers semantically similar nodes via tag-neighbor similarity and
  deletes the lower-scored one. Returns immediately; the consolidation runs
  in the background. Subscribe to Notifier events (`:consolidation_completed`)
  to observe results.

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

  # -- Private --

  defp lookup_repo(repo_id, opts) do
    sup_name = Keyword.get(opts, :supervisor, @default_sup)
    repo_registry = MneSupervisor.repo_registry_name(sup_name)

    case Registry.lookup(repo_registry, repo_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, NotFoundError.exception(resource: :repo, id: repo_id)}
    end
  end

  defp lookup_session(session_id, opts) do
    sup_name = Keyword.get(opts, :supervisor, @default_sup)
    registry = MneSupervisor.registry_name(sup_name)

    case Registry.lookup(registry, session_id) do
      [{pid, nil}] -> {:ok, pid}
      [] -> {:error, NotFoundError.exception(resource: :session, id: session_id)}
    end
  end

  defp await_and_commit(pid, retries_remaining, poll_opts) do
    case poll_until_settled(pid, poll_opts) do
      :ready ->
        Session.commit(pid)

      :idle ->
        :ok

      :failed when retries_remaining > 0 ->
        case Session.commit(pid) do
          :ok -> await_and_commit(pid, retries_remaining - 1, poll_opts)
          {:error, _} = error -> error
        end

      :failed ->
        {:error, PipelineError.exception(reason: :extraction_failed)}

      :timeout ->
        {:error, PipelineError.exception(reason: :extraction_timeout)}
    end
  end

  defp poll_until_settled(pid, opts) do
    max_polls = Keyword.get(opts, :max_polls, 200)
    interval = Keyword.get(opts, :poll_interval, 50)

    Enum.reduce_while(1..max_polls, :timeout, fn _, _ ->
      case Session.state(pid) do
        :extracting ->
          Process.sleep(interval)
          {:cont, :timeout}

        :ready ->
          {:halt, :ready}

        :failed ->
          {:halt, :failed}

        :idle ->
          {:halt, :idle}

        _other ->
          {:halt, :timeout}
      end
    end)
  end
end
