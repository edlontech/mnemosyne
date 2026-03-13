defmodule Mnemosyne do
  @moduledoc """
  Agentic memory library built on a three-layer knowledge graph architecture.

  Provides a public API for session management (write path),
  memory retrieval (read path), and graph management.
  """

  alias Mnemosyne.Errors.Framework.NotFoundError
  alias Mnemosyne.Errors.Framework.PipelineError
  alias Mnemosyne.Errors.Framework.StorageError
  alias Mnemosyne.MemoryStore
  alias Mnemosyne.Session
  alias Mnemosyne.Supervisor, as: MneSupervisor

  @default_sup Mnemosyne.Supervisor

  @doc """
  Starts a new memory session with the given goal.

  The session is started under the SessionSupervisor and automatically
  begins collecting observations. Returns `{:ok, session_id}`.
  """
  @spec start_session(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def start_session(goal, opts \\ []) do
    sup_name = Keyword.get(opts, :supervisor, @default_sup)
    registry = MneSupervisor.registry_name(sup_name)
    task_sup = MneSupervisor.task_supervisor_name(sup_name)
    store = MneSupervisor.memory_store_name(sup_name)
    session_sup = MneSupervisor.session_supervisor_name(sup_name)

    defaults = MemoryStore.get_session_defaults(store)

    session_opts = [
      registry: registry,
      task_supervisor: task_sup,
      memory_store: store,
      config: Keyword.get(opts, :config, defaults.config),
      llm: Keyword.get(opts, :llm, defaults.llm),
      embedding: Keyword.get(opts, :embedding, defaults.embedding)
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

  @doc "Appends an observation-action pair to the session."
  @spec append(String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, Mnemosyne.Errors.error()}
  def append(session_id, observation, action, opts \\ []) do
    with {:ok, pid} <- lookup_session(session_id, opts) do
      Session.append(pid, observation, action)
    end
  end

  @doc "Closes the current episode, triggering extraction."
  @spec close(String.t(), keyword()) :: :ok | {:error, Mnemosyne.Errors.error()}
  def close(session_id, opts \\ []) do
    with {:ok, pid} <- lookup_session(session_id, opts) do
      Session.close(pid)
    end
  end

  @doc "Commits the extracted changeset to the MemoryStore."
  @spec commit(String.t(), keyword()) :: :ok | {:error, Mnemosyne.Errors.error()}
  def commit(session_id, opts \\ []) do
    with {:ok, pid} <- lookup_session(session_id, opts) do
      Session.commit(pid)
    end
  end

  @doc "Discards the session result without committing."
  @spec discard(String.t(), keyword()) :: :ok | {:error, Mnemosyne.Errors.error()}
  def discard(session_id, opts \\ []) do
    with {:ok, pid} <- lookup_session(session_id, opts) do
      Session.discard(pid)
    end
  end

  @doc "Returns the current state of a session."
  @spec session_state(String.t(), keyword()) :: atom() | {:error, NotFoundError.t()}
  def session_state(session_id, opts \\ []) do
    with {:ok, pid} <- lookup_session(session_id, opts) do
      Session.state(pid)
    end
  end

  @doc """
  Closes the episode and waits for extraction to complete, then commits.

  Retries on transient failures up to `max_retries` (default 2).
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

  @doc "Retrieves relevant memories for the given query."
  @spec recall(String.t(), keyword()) :: {:ok, term()} | {:error, Mnemosyne.Errors.error()}
  def recall(query, opts \\ []) do
    store = store_name(opts)
    MemoryStore.recall(store, query, opts)
  end

  @doc "Retrieves memories with session context augmenting the query."
  @spec recall_in_context(String.t(), String.t(), keyword()) ::
          {:ok, term()} | {:error, Mnemosyne.Errors.error()}
  def recall_in_context(session_id, query, opts \\ []) do
    store = store_name(opts)

    case lookup_session(session_id, opts) do
      {:ok, pid} ->
        MemoryStore.recall_in_context(store, pid, query, opts)

      {:error, %NotFoundError{}} ->
        MemoryStore.recall(store, query, opts)
    end
  end

  @doc "Returns the current knowledge graph."
  @spec get_graph(keyword()) :: Mnemosyne.Graph.t()
  def get_graph(opts \\ []) do
    store = store_name(opts)
    MemoryStore.get_graph(store)
  end

  @doc "Applies a changeset to the knowledge graph."
  @spec apply_changeset(Mnemosyne.Graph.Changeset.t(), keyword()) ::
          :ok | {:error, StorageError.t()}
  def apply_changeset(changeset, opts \\ []) do
    store = store_name(opts)
    MemoryStore.apply_changeset(store, changeset)
  end

  @doc "Deletes nodes from the knowledge graph."
  @spec delete_nodes([String.t()], keyword()) :: :ok | {:error, StorageError.t()}
  def delete_nodes(node_ids, opts \\ []) do
    store = store_name(opts)
    MemoryStore.delete_nodes(store, node_ids)
  end

  # -- Private --

  defp lookup_session(session_id, opts) do
    sup_name = Keyword.get(opts, :supervisor, @default_sup)
    registry = MneSupervisor.registry_name(sup_name)

    case Registry.lookup(registry, session_id) do
      [{pid, nil}] -> {:ok, pid}
      [] -> {:error, NotFoundError.exception(resource: :session, id: session_id)}
    end
  end

  defp store_name(opts) do
    sup_name = Keyword.get(opts, :supervisor, @default_sup)
    MneSupervisor.memory_store_name(sup_name)
  end

  defp await_and_commit(pid, retries_remaining, poll_opts) do
    case poll_until_settled(pid, poll_opts) do
      :ready ->
        Session.commit(pid)

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

        _other ->
          {:halt, :timeout}
      end
    end)
  end
end
