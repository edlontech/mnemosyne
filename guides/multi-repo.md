# Multi-Repository Isolation

Mnemosyne supports multiple isolated knowledge graphs under a single supervision tree. This guide covers when and how to use multiple repositories.

## When to Use Multiple Repos

Each repository gets its own MemoryStore process and GraphBackend instance. Knowledge in one repo is completely invisible to another. Use separate repos when:

- **Different projects or domains** should not cross-pollinate knowledge
- **Per-user isolation** in multi-tenant applications
- **Separate contexts** within the same agent (e.g., work knowledge vs. personal knowledge)
- **Testing** alongside production graphs

## Opening and Closing Repos

```elixir
# Open repos with different backends
{:ok, _} = Mnemosyne.open_repo("project-alpha",
  backend: {Mnemosyne.GraphBackends.InMemory,
    persistence: {Mnemosyne.GraphBackends.Persistence.DETS, path: "priv/memory/alpha.dets"}})

{:ok, _} = Mnemosyne.open_repo("project-beta",
  backend: {Mnemosyne.GraphBackends.InMemory, []})

# List open repos
["project-alpha", "project-beta"] = Mnemosyne.list_repos()

# Close when done
:ok = Mnemosyne.close_repo("project-alpha")
```

Opening a repo that's already open returns an error:

```elixir
{:error, %Mnemosyne.Errors.Framework.RepoError{reason: :already_open}} =
  Mnemosyne.open_repo("project-alpha", backend: {Mnemosyne.GraphBackends.InMemory, []})
```

## Per-Repo Configuration

Shared configuration (LLM model, embedding model) is set once at supervisor startup. Each repo inherits these defaults but can override them:

```elixir
# Shared defaults from supervisor
{Mnemosyne.Supervisor,
  config: %Mnemosyne.Config{
    llm: %{model: "gpt-4o-mini", opts: %{}},
    embedding: %{model: "text-embedding-3-small", opts: %{}}
  },
  llm: Mnemosyne.Adapters.SycophantLLM,
  embedding: Mnemosyne.Adapters.SycophantEmbedding}

# This repo uses a different LLM adapter
Mnemosyne.open_repo("special-project",
  backend: {Mnemosyne.GraphBackends.InMemory, []},
  llm: MyApp.ClaudeLLMAdapter)
```

Backend configuration is always per-repo since each repo needs its own storage.

## Sessions and Repos

Sessions are bound to a specific repo via the `:repo` option:

```elixir
{:ok, session_id} = Mnemosyne.start_session("Explore caching", repo: "project-alpha")
```

All session operations (append, close, commit) route to the bound repo's MemoryStore. You cannot move a session between repos.

## All Operations Are Repo-Scoped

Every operation takes a `repo_id` as its first argument:

```elixir
# Recall
{:ok, memories} = Mnemosyne.recall("project-alpha", "How does caching work?")

# Graph inspection
graph = Mnemosyne.get_graph("project-alpha")

# Direct mutations
:ok = Mnemosyne.apply_changeset("project-alpha", changeset)
:ok = Mnemosyne.delete_nodes("project-alpha", ["node-1"])

# Maintenance
{:ok, _} = Mnemosyne.consolidate_semantics("project-alpha")
{:ok, _} = Mnemosyne.decay_nodes("project-alpha")
```

Operating on a closed or nonexistent repo returns a `NotFoundError`:

```elixir
{:error, %Mnemosyne.Errors.Framework.NotFoundError{resource: :repo}} =
  Mnemosyne.recall("nonexistent", "query")
```

## Supervision Architecture

Under the hood, each repo is a child of the `RepoSupervisor` (a `DynamicSupervisor`):

```
Mnemosyne.Supervisor (rest_for_one)
  |-- SessionRegistry
  |-- RepoRegistry
  |-- TaskSupervisor
  |-- RepoSupervisor (DynamicSupervisor)
  |     |-- MemoryStore "project-alpha"
  |     |-- MemoryStore "project-beta"
  |-- SessionSupervisor (DynamicSupervisor)
        |-- Session "session_abc123"
```

The `rest_for_one` strategy means if the RepoSupervisor crashes, all sessions restart too. Each MemoryStore is registered in the RepoRegistry by its string ID.

## Multiple Supervisor Instances

You can run multiple independent Mnemosyne instances by passing a custom `:name`:

```elixir
{Mnemosyne.Supervisor,
  name: MyApp.WorkMemory,
  config: work_config,
  llm: work_llm,
  embedding: work_embedding}

{Mnemosyne.Supervisor,
  name: MyApp.PersonalMemory,
  config: personal_config,
  llm: personal_llm,
  embedding: personal_embedding}
```

Then pass `:supervisor` in all operations:

```elixir
Mnemosyne.open_repo("repo", backend: backend, supervisor: MyApp.WorkMemory)
Mnemosyne.start_session("goal", repo: "repo", supervisor: MyApp.WorkMemory)
Mnemosyne.recall("repo", "query", supervisor: MyApp.WorkMemory)
```

## Next Steps

- [Getting Started](getting-started.md) - basic setup with a single repo
- [Sessions and Episodes](sessions-and-episodes.md) - session lifecycle within a repo
- [Custom Backends](custom-backends.md) - each repo can use a different backend
