# Getting Started

This guide installs Mnemosyne, starts its supervisor, opens a repository, ingests a complete trajectory, and recalls memory.

## Installation

```elixir
def deps do
  [
    {:mnemosyne, github: "edlontech/mnemosyne"}
  ]
end
```

```bash
mix deps.get
mix compile
```

## Start the Supervisor

Add Mnemosyne to your application's supervision tree:

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

The supervisor requires a `Mnemosyne.Config`, an `Mnemosyne.LLM` implementation, and an `Mnemosyne.Embedding` implementation. The built-in Sycophant adapters can be used when that optional dependency is installed.

## Open a Repository

All operations are scoped to an isolated repository:

```elixir
{:ok, _pid} =
  Mnemosyne.open_repo("my-project",
    backend:
      {Mnemosyne.GraphBackends.InMemory,
       persistence:
         {Mnemosyne.GraphBackends.Persistence.DETS,
          path: "priv/memory/my-project.dets"}}
  )
```

Use `{Mnemosyne.GraphBackends.InMemory, []}` when persistence is not required.

## Ingest a Complete Trajectory

Your application owns the interaction while it is in progress. Once complete, submit the goal, ordered steps, stable source ID, and metadata together:

```elixir
trajectory = %Mnemosyne.Trajectory{
  source_id: "trip-planning-42",
  goal: "Help the user plan a trip",
  steps: [
    %{
      observation: "The user wants to visit Tokyo",
      action: "Asked about travel dates"
    },
    %{
      observation: "The user plans to travel next March for two weeks",
      action: "Suggested an itinerary"
    }
  ],
  metadata: %{channel: "assistant", schema: 1}
}

{:ok, receipt} = Mnemosyne.ingest("my-project", trajectory)
```

The call returns only after the graph and durable source record are stored. An equal retry returns the exact original receipt. Reusing the source ID in this repo with a different goal, step order/content, metadata, or fingerprint version returns a source-conflict error.

Equal pending calls coalesce, and the first admitted call owns their execution options. Your application remains responsible for unfinished state, retry policy, and deciding which complete histories may run concurrently.

## Recall Memory

```elixir
{:ok, memories} =
  Mnemosyne.recall("my-project", "What are the user's travel preferences?")
```

For an active task, provide transient context directly:

```elixir
{:ok, memories} =
  Mnemosyne.recall("my-project", "What should I do next?",
    source_id: "trip-planning-43",
    context: %{
      goal: "Plan another trip",
      recent_steps: [
        %{observation: "The user mentioned Kyoto", action: "Compared destinations"}
      ]
    }
  )
```

Only the last three recent steps augment the query. Context is not stored, and `source_id` is optional correlation metadata.

## Repository Lifecycle

```elixir
Mnemosyne.list_repos()
:ok = Mnemosyne.close_repo("my-project")
```

## Next Steps

- [Core Concepts](core-concepts.md)
- [Trajectory Ingestion](trajectory-ingestion.md)
- [Extraction Profiles](extraction-profiles.md)
- [Retrieval and Recall](retrieval-and-recall.md)
- [Custom Adapters](custom-adapters.md)
