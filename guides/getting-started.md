# Getting Started

This guide walks you through installing Mnemosyne, setting up the supervisor, and running your first memory session.

## Installation

Add `mnemosyne` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:mnemosyne, github: "edlontech/mnemosyne"}
  ]
end
```

Then fetch and compile:

```bash
mix deps.get
mix compile
```

## Setting Up the Supervisor

Mnemosyne runs under its own supervision tree. Add it to your application's supervisor in `lib/my_app/application.ex`:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      {Mnemosyne.Supervisor,
        config: %Mnemosyne.Config{
          llm: %{model: "gpt-4o-mini", opts: %{}},
          embedding: %{model: "text-embedding-3-small", opts: %{}}
        },
        llm: MyApp.LLMAdapter,
        embedding: MyApp.EmbeddingAdapter}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  end
end
```

The supervisor requires three things:

- **config** - A `Mnemosyne.Config` struct with LLM and embedding model settings
- **llm** - A module implementing the `Mnemosyne.LLM` behaviour
- **embedding** - A module implementing the `Mnemosyne.Embedding` behaviour

If you're using [Sycophant](https://github.com/edlontech/sycophant), you can use the built-in adapters:

```elixir
{Mnemosyne.Supervisor,
  config: %Mnemosyne.Config{
    llm: %{model: "gpt-4o-mini", opts: %{}},
    embedding: %{model: "text-embedding-3-small", opts: %{}}
  },
  llm: Mnemosyne.Adapters.SycophantLLM,
  embedding: Mnemosyne.Adapters.SycophantEmbedding}
```

## Opening a Repository

All graph operations are scoped to a **repository**. A repository is an isolated knowledge graph with its own storage backend.

```elixir
{:ok, _pid} = Mnemosyne.open_repo("my-project",
  backend: {Mnemosyne.GraphBackends.InMemory, []})
```

For persistent storage across restarts, use the DETS persistence layer:

```elixir
{:ok, _pid} = Mnemosyne.open_repo("my-project",
  backend: {Mnemosyne.GraphBackends.InMemory,
    persistence: {Mnemosyne.GraphBackends.Persistence.DETS, path: "priv/memory/my-project.dets"}})
```

## Running a Session

Sessions are the write interface. A session collects observation-action pairs, groups them into trajectories, and extracts knowledge using LLM calls.

```elixir
# Start a session tied to a repo
{:ok, session_id} = Mnemosyne.start_session("Help user plan a trip", repo: "my-project")

# Feed in observations and actions
:ok = Mnemosyne.append(session_id, "User wants to visit Tokyo", "Asking about travel dates")
:ok = Mnemosyne.append(session_id, "User says next March for 2 weeks", "Suggesting itinerary")

# Close the episode and commit extracted knowledge
:ok = Mnemosyne.close_and_commit(session_id)
```

`close_and_commit/1` is a convenience that closes the episode, waits for LLM extraction to finish, and commits the resulting knowledge graph changeset.

## Recalling Memories

Once knowledge is committed, query it with `recall/3`:

```elixir
{:ok, %{candidates: candidates}} = Mnemosyne.recall("my-project", "What are the user's travel preferences?")
```

The result contains candidates partitioned by node type (`:semantic`, `:procedural`, `:episodic`, etc.), each scored by relevance.

If you have an active session, use `recall_in_context/4` to augment the query with the session's current state:

```elixir
{:ok, memories} = Mnemosyne.recall_in_context("my-project", session_id, "What did we discuss?")
```

## Cleaning Up

```elixir
# Close a repo when done
:ok = Mnemosyne.close_repo("my-project")

# List open repos
Mnemosyne.list_repos()
```

## Next Steps

- [Core Concepts](core-concepts.md) - understand episodes, trajectories, and the three memory types
- [Sessions and Episodes](sessions-and-episodes.md) - session lifecycle in detail
- [Retrieval and Recall](retrieval-and-recall.md) - how recall works and how to tune it
- [Custom Adapters](custom-adapters.md) - writing your own LLM and embedding adapters
