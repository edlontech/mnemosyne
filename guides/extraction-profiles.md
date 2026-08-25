# Extraction Profiles

Extraction profiles steer domain-agnostic prompts and retrieval weighting without changing pipeline schemas.

## How Profiles Work

A `%Mnemosyne.ExtractionProfile{}` provides:

1. prompt overlays appended to selected pipeline system messages;
2. per-node-type value-function parameter overrides.

Mnemosyne includes:

- `Mnemosyne.ExtractionProfile.coding/0` prioritizes API behavior, error patterns, architecture, debugging procedures, and concrete outcomes; it slightly elevates procedural retrieval.
- `Mnemosyne.ExtractionProfile.research/0` prioritizes sourced claims, contradictions, high-level methodology, novelty, and accuracy; it elevates semantic retrieval and lowers procedural weight.
- `Mnemosyne.ExtractionProfile.customer_support/0` prioritizes product behavior, known issues, diagnostics, resolution workflows, escalation criteria, and successful resolution; it slightly elevates procedural retrieval.

## Repo Default

Set the profile in the repo's config:

```elixir
config = %Mnemosyne.Config{
  llm: %{model: "gpt-4o-mini", opts: %{}},
  embedding: %{model: "text-embedding-3-small", opts: %{}},
  extraction_profile: Mnemosyne.ExtractionProfile.coding()
}

{Mnemosyne.Supervisor,
  config: config,
  llm: llm_adapter,
  embedding: embedding_adapter}
```

Ingestion and recall use the repository config by default. Only `ingest/3` can replace it for one operation; `recall/3` always uses the repository config.

## Per-Ingestion Override

Pass a complete trajectory and replacement config to blocking `ingest/3`:

```elixir
research_config = %{
  config
  | extraction_profile: Mnemosyne.ExtractionProfile.research()
}

trajectory = %Mnemosyne.Trajectory{
  source_id: "cache-research-42",
  goal: "Investigate cache invalidation strategies",
  steps: [
    %{
      observation: "The paper compares TTL and event-driven invalidation",
      action: "Recorded the measured trade-offs"
    }
  ],
  metadata: %{corpus: "cache-study", schema: 1}
}

{:ok, receipt} =
  Mnemosyne.ingest("my-project", trajectory, config: research_config)
```

The replacement `config`, adapters, and `llm_opts` control this ingestion but do not enter payload identity. Ordinary trajectory embeddings use the replacement config's embedding options; per-call `embedding_opts` currently reaches only write-time intent merging. Equal pending submissions share the first admitted call's execution options; equal stored retries return the original receipt without extracting again. Recall continues to use the repository config.

## Custom Profiles

```elixir
profile = %Mnemosyne.ExtractionProfile{
  name: :legal,
  domain_context: "Legal document analysis and contract review.",
  overlays: %{
    get_semantic: "Prioritize obligations, defined terms, liabilities, and jurisdiction.",
    get_procedural: "Extract review checklists and escalation criteria.",
    get_reward: "Reward completeness, accurate risk flags, and explicit ambiguity."
  },
  value_function_overrides: %{
    semantic: %{base_floor: 0.2}
  }
}
```

Overlays are keyed by pipeline step and apply only when present:

| Pipeline Stage | Keys |
|----------------|------|
| Episode | `:get_state`, `:get_subgoal`, `:get_reward` |
| Structuring | `:get_state`, `:get_semantic`, `:get_procedural`, `:get_return` |
| Retrieval | `:get_mode`, `:get_plan` |
| Hop control | `:multi_hop_control`, `:get_refined_query` |
| Reasoning | `:reason_episodic`, `:reason_semantic`, `:reason_procedural` |
| Intent merger | `:merge_intent` |
| Semantic consolidation | `:merge_semantic` |

Value-function overrides merge over the base per-type parameters. Model overrides in `config.overrides` select how a step executes; profile overlays control what that step asks for.

## Next Steps

- [Core Concepts](core-concepts.md)
- [Trajectory Ingestion](trajectory-ingestion.md)
- [Retrieval and Recall](retrieval-and-recall.md)
- [Custom Adapters](custom-adapters.md)
