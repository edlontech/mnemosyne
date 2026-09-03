# Multi-Repository Isolation

Mnemosyne supports multiple isolated knowledge graphs under one supervision tree. Each repository has its own `MemoryStore` process and `GraphBackend` state.

## When to Use Multiple Repos

Use separate repos for project, tenant, user, environment, or domain boundaries that must not share knowledge.

```elixir
{:ok, _} =
  Mnemosyne.open_repo("project-alpha",
    backend:
      {Mnemosyne.GraphBackends.InMemory,
       persistence:
         {Mnemosyne.GraphBackends.Persistence.DETS,
          path: "priv/memory/alpha.dets"}},
    telemetry_labels: %{environment: :production, team: "search"}
  )

{:ok, _} =
  Mnemosyne.open_repo("project-beta",
    backend: {Mnemosyne.GraphBackends.InMemory, []},
    telemetry_labels: %{environment: :staging, team: "platform"}
  )
```

For repository cost observability, `repo_id` is the tenant identity. `:telemetry_labels` is an optional flat map with string or atom keys and scalar string, atom, number, or boolean values. Labels live only in the open `MemoryStore`; they are not stored in the graph backend. Supply them again when reopening a repo.

Do not put secrets in labels. Keep values bounded and low-cardinality: request IDs, user IDs, prompts, and unbounded source IDs create expensive or unusable metric dimensions.

`Mnemosyne.list_repos/1` lists open IDs, and `Mnemosyne.close_repo/2` closes one repository. Opening an existing ID returns `RepoError` with `:already_open`; using a missing ID returns `NotFoundError` for `:repo`.

## Repo-Scoped Source IDs

A trajectory's `source_id` is stable within its target repo, not globally unique. These two complete trajectories have independent identity records:

```elixir
trajectory = %Mnemosyne.Trajectory{
  source_id: "task-42",
  goal: "Explore caching",
  steps: [
    %{observation: "A cache miss occurred", action: "Inspected the key namespace"}
  ],
  metadata: %{workflow: "diagnosis"}
}

{:ok, alpha_receipt} = Mnemosyne.ingest("project-alpha", trajectory)
{:ok, beta_receipt} = Mnemosyne.ingest("project-beta", trajectory)
```

Within either repo, an equal retry returns that repo's exact original receipt and a different payload for `"task-42"` conflicts. Source records and graph content never cross repo boundaries.

All other operations also take a repo ID first:

```elixir
{:ok, memories} = Mnemosyne.recall("project-alpha", "How does caching work?")
graph = Mnemosyne.get_graph("project-alpha")
:ok = Mnemosyne.delete_nodes("project-alpha", ["node-1"])
:ok = Mnemosyne.decay_nodes("project-alpha")
```

Deleting or decaying nodes in a repo leaves its ingestion records intact.

## Repository Cost Telemetry

Attach host telemetry handlers to the canonical terminal events. `:stop` records completed adapter calls, including returned adapter errors; `:exception` records raised, thrown, or exited calls. The `:start` event supports timing only and is not a usage or cost record.

```elixir
:telemetry.attach_many(
  "my-app.mnemosyne-costs",
  [
    [:mnemosyne, :model, :call, :stop],
    [:mnemosyne, :model, :call, :exception]
  ],
  &MyApp.Telemetry.handle_model_call/4,
  nil
)
```

Both terminal events include `repo_id`, nested `labels`, `operation`, optional `source_id`, `kind`, `callback`, `adapter`, `step`, `requested_model`, and `status`. Stop-event metadata also includes `response_model` and optional `currency`; exception-event metadata instead includes `exception_kind`, `reason`, and `stacktrace`. Terminal measurements include native `duration`, while stop measurements may also include recognized provider-reported token or cost fields. Flatten nested `labels` only in the host exporter when its metric backend requires it; Mnemosyne keeps them nested to avoid collisions with trusted fields.

Aggregate `total_cost` by `repo_id` in the host observability system. Do not infer a total from component costs, treat missing cost as zero, or double count existing LLM or embedding adapter events. Those adapter events remain backward-compatible but are non-canonical for per-repo cost aggregation.

Mnemosyne does not price, aggregate, persist costs, invoice, budget, or provide operation-level labels. It emits observability data, not a billing ledger. Multi-repo tenant grouping, billing ledgers, budgets, and operation-level custom labels are not provided.

## Configuration Boundaries

Supervisor configuration supplies shared defaults. A repo can override config and adapters when opened. A complete ingestion can replace its config and adapters and pass pipeline-wide `llm_opts`; ordinary trajectory embeddings use config options, while per-call `embedding_opts` currently applies only to write-time intent merging. These execution choices do not affect payload identity. Recall uses the repository config and adapters.

Backend configuration is always per repo because each repo owns separate backend state.

## Supervision Architecture

```text
Mnemosyne.Supervisor (rest_for_one)
  |-- RepoRegistry
  |-- TaskSupervisor
  |-- RepoSupervisor (DynamicSupervisor)
        |-- MemoryStore "project-alpha"
        |-- MemoryStore "project-beta"
```

Ingestion, recall, write, and maintenance tasks use the shared `TaskSupervisor`; each repo's `MemoryStore` owns admission and backend state.

## Multiple Supervisor Instances

Run independent Mnemosyne instances with custom names:

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

Pass the matching supervisor to every operation:

```elixir
Mnemosyne.open_repo("repo", backend: backend, supervisor: MyApp.WorkMemory)
Mnemosyne.ingest("repo", trajectory, supervisor: MyApp.WorkMemory)
Mnemosyne.recall("repo", "query", supervisor: MyApp.WorkMemory)
```

## Next Steps

- [Getting Started](getting-started.md)
- [Trajectory Ingestion](trajectory-ingestion.md)
- [Custom Backends](custom-backends.md)
