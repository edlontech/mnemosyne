# Retrieval and Recall

This guide explains how Mnemosyne retrieves relevant memories from the knowledge graph, how scoring works, and how to tune retrieval parameters.

## How Recall Works

When you call `Mnemosyne.recall/3`, the retrieval pipeline runs through four stages:

### 1. Mode Classification

The query is classified into one of four retrieval modes using an LLM call:

| Mode | Description | Target Node Types |
|------|-------------|-------------------|
| `:semantic` | Factual queries ("What is X?") | `semantic` |
| `:procedural` | How-to queries ("How do I X?") | `procedural` |
| `:episodic` | Experience queries ("What happened when?") | `semantic` (mapped to provenance-linked `episodic`) |
| `:mixed` | Queries spanning multiple types | `episodic`, `semantic`, `procedural`, `subgoal` |

Episodic queries retrieve over the semantic graph and map the results back to the episodic nodes they were extracted from -- an episode's score aggregates the scores of all retrieved facts that trace back to it. When the graph has no semantic layer (or no provenance links), episodic retrieval falls back to direct embedding search over episodic and subgoal nodes.

### 2. Tag Generation

The pipeline generates retrieval tags -- short concept phrases that capture the query's key aspects. These tags are embedded alongside the query itself, giving the retrieval system multiple vectors to match against.

### 3. Candidate Scoring (Hop 0)

The graph backend scores all nodes of the target types against both the query embedding and tag embeddings. Each node's relevance is the maximum of:
- Cosine similarity with the query vector
- Maximum cosine similarity across all tag vectors

This raw relevance is then combined with node metadata through the value function:

```
score = relevance * recency_factor * frequency_factor * reward_factor
```

Candidates below the per-type threshold are filtered out, and only the top-k per type survive.

### 4. Controlled Multi-Hop Traversal

After the initial candidates are found, an LLM controller assesses each hop: if the accumulated candidates already contain enough evidence to answer the query, retrieval stops early. Otherwise the controller selects up to two focus candidates -- typically ones naming a bridge entity that must be resolved next -- whose content is concatenated with the query to form the next-hop query embedding.

Each continued hop then expands through routing nodes (Tags for semantic mode, Intents for procedural mode) to discover related knowledge:

```
Candidate semantic node
  --> linked Tag nodes
    --> other semantic nodes linked to those Tags
      --> score and merge with initial candidates
```

On top of the routing expansion, retrieval tags are regenerated per hop conditioned on the query and what has been retrieved so far, up to `config.refinement_budget` LLM calls per recall (default: 2, capped at `max_hops`). The regenerated tag embeddings inject fresh candidates outside the local neighborhood.

This runs for up to `max_hops` iterations (default: 2), each time re-ranking the merged candidate set. The controller degrades gracefully: on any LLM failure it simply continues the hop without focus candidates.

For episodic mode, an additional provenance expansion step follows Source nodes back to their originating episodes, applying a decay factor (0.5) to the parent's score.

## Value Function

The default value function (`Mnemosyne.ValueFunction.Default`) scores nodes using four multiplicative factors:

### Relevance

Cosine similarity between the query/tag embeddings and the node's embedding. This is the primary signal.

### Recency Factor

Exponential decay based on hours since last access:

```
recency = exp(-lambda * hours_since_last_access)
```

Default `lambda`: 0.01. At this rate, a node accessed 24 hours ago retains ~78% of its recency score; after a week, ~19%.

### Frequency Factor

Saturating function of access count:

```
frequency = max(base_floor, access_count / (access_count + k))
```

Default `k`: 5, `base_floor`: 0.3. A node accessed once scores 0.3; five times scores 0.5; twenty times scores 0.8.

### Reward Factor

Sigmoid of average cumulative reward:

```
reward = 1 / (1 + exp(-beta * avg_reward))
```

Default `beta`: 1.0. Nodes from high-reward trajectories score higher. Nodes with no reward history score 1.0 (neutral).

## Tuning Parameters

Value function parameters are configured per node type in `Mnemosyne.Config`:

```elixir
config = %Mnemosyne.Config{
  llm: %{model: "gpt-4o-mini", opts: %{}},
  embedding: %{model: "text-embedding-3-small", opts: %{}},
  value_function: %{
    module: Mnemosyne.ValueFunction.Default,
    params: %{
      semantic: %{threshold: 0.1, top_k: 30, lambda: 0.005, k: 10, base_floor: 0.2, beta: 1.5},
      procedural: %{threshold: 0.8, top_k: 10, lambda: 0.01, k: 5, base_floor: 0.3, beta: 1.0},
      episodic: %{threshold: 0.0, top_k: 30, lambda: 0.01, k: 5, base_floor: 0.3, beta: 1.0}
    }
  }
}
```

### Parameter Reference

| Parameter | Default | Effect |
|-----------|---------|--------|
| `threshold` | varies | Minimum score to include a candidate. Higher = stricter filtering. |
| `top_k` | varies | Maximum candidates per node type. |
| `lambda` | 0.01 | Recency decay rate. Higher = faster decay, stronger preference for recent nodes. |
| `k` | 5 | Frequency saturation constant. Higher = slower ramp-up for frequently accessed nodes. |
| `base_floor` | 0.3 | Minimum frequency factor. Prevents never-accessed nodes from scoring zero. |
| `beta` | 1.0 | Reward sensitivity. Higher = stronger discrimination between high and low reward nodes. |

### Default Thresholds by Type

| Type | Threshold | Top K |
|------|-----------|-------|
| `semantic` | 0.0 | 20 |
| `procedural` | 0.8 | 10 |
| `episodic` | 0.0 | 30 |
| `subgoal` | 0.75 | 10 |
| `tag` | 0.9 | 10 |
| `source` | 0.0 | 50 |
| `intent` | 0.7 | 10 |

Procedural nodes have a high threshold (0.8) because vague procedural matches tend to be unhelpful. Semantic and episodic nodes use 0.0 to let the value function handle ranking.

These defaults can be overridden per node type via [extraction profiles](extraction-profiles.md), which merge domain-specific parameter tweaks on top of config-level settings.

## Active-Task Context

The caller can augment `recall/3` with transient active-task state:

```elixir
{:ok, memories} =
  Mnemosyne.recall("my-repo", "What patterns apply?",
    source_id: "task-42",
    context: %{
      goal: "Diagnose intermittent timeouts",
      recent_steps: [
        %{
          observation: "The request timed out behind the proxy",
          action: "Inspected forwarded headers"
        }
      ]
    }
  )
```

The goal and at most the last three recent observation/action pairs augment the query in caller order. Context is used only by retrieval and reasoning: it is not persisted, does not create graph nodes, and does not reserve the source ID. `source_id` is optional correlation metadata for traces, notifier events, and telemetry; it does not change candidate scoring.

## Custom Value Functions

Implement the `Mnemosyne.ValueFunction` behaviour to create your own scoring logic:

```elixir
defmodule MyApp.ValueFunction do
  @behaviour Mnemosyne.ValueFunction

  @impl true
  def score(relevance, node, metadata, params) do
    # Your scoring logic here
    # node gives you access to the node struct and type
    # metadata is a NodeMetadata struct (or nil)
    # params are the per-type config values
    relevance
  end
end
```

Register it in your config:

```elixir
value_function: %{
  module: MyApp.ValueFunction,
  params: %{...}
}
```

## Result Structure

`recall/3` runs the retrieval pipeline and then passes the candidates through a **reasoning** step that synthesizes them into typed summaries using LLM calls. The final result is a `RecallResult` struct:

```elixir
%Mnemosyne.Pipeline.RecallResult{
  reasoned: %Mnemosyne.Pipeline.Reasoning.ReasonedMemory{
    episodic: "The user previously planned a trip to Kyoto...",
    semantic: "The user prefers 2-week trips and travels in March...",
    procedural: "When discussing destinations, first confirm travel dates..."
  },
  touched_nodes: [
    %Mnemosyne.Pipeline.Retrieval.TouchedNode{
      id: "sem_42", type: :semantic, score: 0.92, phase: :initial, hop: 0
    },
    %Mnemosyne.Pipeline.Retrieval.TouchedNode{
      id: "ep_7", type: :episodic, score: 0.85, phase: :multi_hop, hop: 1
    }
  ],
  trace: %Mnemosyne.Notifier.Trace.Recall{
    mode: :mixed,
    tags: ["travel", "preferences"],
    candidate_count: 5,
    phase_timings: %{hop_0: 1200, multi_hop: 3400, ...}
  }
}
```

The `reasoned` field contains natural-language summaries per memory type (`nil` when no candidates of that type were found). The reasoning step runs in parallel across the three types.

The `touched_nodes` field lists every node that contributed to the result, sorted by score. Each entry carries the node's origin phase (`:initial`, `:multi_hop`, `:refinement`, or `:provenance`) and hop number. When `config.trace_verbosity` is `:detailed`, the full node struct is included in the `node` field; at `:summary` (the default) it is `nil`.

The `trace` field provides execution metadata: classified mode, generated tags, per-phase timings, candidate counts per hop, and composite scores per node.

## Next Steps

- [Core Concepts](core-concepts.md) - understand the knowledge graph structure
- [Extraction Profiles](extraction-profiles.md) - domain-specific tuning for extraction and retrieval
- [Graph Maintenance](graph-maintenance.md) - consolidation and decay
- [Custom Backends](custom-backends.md) - implement your own graph backend with optimized queries
