# Extraction Profiles

Mnemosyne's extraction pipeline is domain-agnostic by default -- it extracts the same kinds of facts, procedures, and rewards regardless of context. Extraction profiles let you steer the pipeline toward domain-specific knowledge without changing output schemas or pipeline structure.

## How Profiles Work

An `ExtractionProfile` injects overlay text into prompt system messages at extraction time. The LLM sees domain-specific guidance after the base instructions, focusing its output on what matters for your use case.

Profiles affect two things:

1. **Prompt overlays** -- per-step text appended to system messages that guide what the LLM extracts
2. **Value function overrides** -- per-node-type parameter tweaks that shift what gets surfaced during recall

## Built-in Profiles

Mnemosyne ships three profiles as factory functions:

### Coding

Tuned for software engineering: debugging, architecture, code patterns.

```elixir
profile = Mnemosyne.ExtractionProfile.coding()
```

- **Semantic extraction**: Prioritizes API behaviors, error patterns, architectural constraints, dependency relationships. Weights empirically verified facts higher.
- **Procedural extraction**: Focuses on debugging steps, resolution patterns, build/deploy procedures. Captures language/framework context in conditions.
- **Reward scoring**: Weights concrete outcomes (tests pass, bug resolved) over discussion.
- **Retrieval**: Slightly elevates procedural nodes (`base_floor: 0.15`).

### Research

Tuned for knowledge work: analysis, literature review, information synthesis.

```elixir
profile = Mnemosyne.ExtractionProfile.research()
```

- **Semantic extraction**: Prioritizes factual claims with evidence, source relationships, contradictions. Distinguishes empirical findings from speculation.
- **Procedural extraction**: Extracts only high-level methodologies and strategies, not granular steps.
- **Reward scoring**: Weights information novelty and accuracy over task completion.
- **Retrieval**: Elevates semantic nodes (`base_floor: 0.15`), deprioritizes procedural (`base_floor: 0.05`).

### Customer Support

Tuned for issue resolution: product knowledge, diagnostics, escalation.

```elixir
profile = Mnemosyne.ExtractionProfile.customer_support()
```

- **Semantic extraction**: Prioritizes product behaviors, known issues, policy rules, customer-reported symptoms.
- **Procedural extraction**: Focuses on resolution workflows, diagnostic trees, escalation criteria. Captures product version and plan tier in conditions.
- **Reward scoring**: Weights issue resolution and correct escalation paths.
- **Retrieval**: Slightly elevates procedural nodes (`base_floor: 0.12`).

## Using a Profile

### At Repo Level

Set the profile in your config. All sessions in the repo use it:

```elixir
config = %Mnemosyne.Config{
  llm: %{model: "gpt-4o-mini", opts: %{}},
  embedding: %{model: "text-embedding-3-small", opts: %{}},
  extraction_profile: Mnemosyne.ExtractionProfile.coding()
}

{Mnemosyne.Supervisor, config: config, llm: llm_adapter, embedding: embedding_adapter}
```

### At Session Level

Override the repo-level profile for a specific session by passing a modified config:

```elixir
research_config = %{config | extraction_profile: Mnemosyne.ExtractionProfile.research()}

{:ok, session_id} = Mnemosyne.start_session("Investigate caching strategies",
  repo: "my-project",
  config: research_config)
```

## Custom Profiles

Build your own profile for any domain:

```elixir
profile = %Mnemosyne.ExtractionProfile{
  name: :legal,
  domain_context: "Legal document analysis and contract review.",
  overlays: %{
    get_semantic: """
    Domain: Legal Analysis.
    Prioritize extracting: contractual obligations, defined terms, liability clauses,
    compliance requirements, jurisdictional constraints. When assessing confidence,
    weight verbatim clause text higher than paraphrased summaries.\
    """,
    get_procedural: """
    Domain: Legal Analysis.
    Focus on: review checklists, compliance verification steps, escalation criteria
    for flagged clauses. In the condition field, capture contract type, jurisdiction,
    and regulatory framework.\
    """,
    get_reward: """
    Domain: Legal Analysis.
    Weight reward toward completeness: Were all relevant clauses identified?
    Were risks properly flagged? Were ambiguities noted?\
    """
  },
  value_function_overrides: %{
    semantic: %{base_floor: 0.2}
  }
}
```

### Overlay Keys

Overlays are keyed by pipeline step. Only steps with an explicit overlay receive injected text -- there is no automatic fallback.

| Pipeline Stage | Available Keys |
|---------------|---------------|
| Episode | `:get_state`, `:get_subgoal`, `:get_reward` |
| Structuring | `:get_semantic`, `:get_procedural`, `:get_return` |
| Retrieval | `:get_mode`, `:get_plan`, `:get_refined_query` |
| Reasoning | `:reason_episodic`, `:reason_semantic`, `:reason_procedural` |
| Intent Merger | `:merge_intent` |

Most profiles only need overlays for `:get_semantic`, `:get_procedural`, and `:get_reward` -- the steps where domain context has the most impact on extraction quality.

### Value Function Overrides

Profiles can shift retrieval emphasis by overriding value function parameters per node type:

```elixir
value_function_overrides: %{
  semantic: %{base_floor: 0.2, top_k: 30},
  procedural: %{base_floor: 0.1, top_k: 5}
}
```

These merge on top of the base config parameters. See the [value function parameter reference](retrieval-and-recall.md#parameter-reference) for available parameters.

## Interaction with Other Config

Extraction profiles are orthogonal to other configuration:

- **Per-step model overrides** (`config.overrides`) control which LLM model runs each step. Profiles control what the prompt asks for. Both can be used together.
- **Value function module** (`config.value_function.module`) is unchanged. Profile overrides only affect the parameters passed to the scoring function.
- **Session config** overrides the entire config, including the profile. There is no merge between session and repo profiles.

## Next Steps

- [Core Concepts](core-concepts.md) -- understand the three memory types that profiles steer
- [Retrieval and Recall](retrieval-and-recall.md) -- value function parameters and tuning
- [Custom Adapters](custom-adapters.md) -- per-step model overrides (complementary to profiles)
