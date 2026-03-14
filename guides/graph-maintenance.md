# Graph Maintenance

As the knowledge graph grows, it accumulates near-duplicate nodes and stale knowledge. Mnemosyne provides two maintenance operations to keep the graph clean.

## Semantic Consolidation

Discovers near-duplicate semantic nodes and deletes the lower-scored one.

```elixir
{:ok, %{deleted: 3, checked: 42}} = Mnemosyne.consolidate_semantics("my-repo")
```

### How It Works

1. Loads all semantic nodes from the graph
2. For each node, walks its Tag links to find tag-neighbor semantic nodes (nodes sharing a Tag)
3. Compares embeddings between tag-neighbors via cosine similarity
4. When similarity exceeds the threshold (default: 0.85), the node with the lower decay score is deleted

The decay score uses the same formula as node decay (recency * frequency * reward), without a relevance component. This ensures the more useful node survives.

### When to Run

Run consolidation after large batches of knowledge extraction, when multiple sessions may have produced overlapping facts. It's a pure embedding comparison with no LLM calls, so it's relatively cheap.

```elixir
# After committing several sessions
Mnemosyne.consolidate_semantics("my-repo")
```

### Tuning the Threshold

The default threshold of 0.85 is conservative -- only very similar nodes get merged. Lower it to be more aggressive:

```elixir
Mnemosyne.consolidate_semantics("my-repo", threshold: 0.75)
```

## Node Decay

Prunes low-utility nodes from the graph based on recency, frequency, and reward signals.

```elixir
{:ok, %{deleted: 5, checked: 38}} = Mnemosyne.decay_nodes("my-repo")
```

### How It Works

1. Loads all nodes of the target types (default: `[:semantic, :procedural]`)
2. Scores each node using the decay formula: `recency * frequency * reward`
3. Deletes nodes scoring below the threshold (default: 0.1)
4. Cleans up orphaned Tag and Intent nodes that lost all their children

### Decay Scoring

The decay score is the same multiplicative formula used during retrieval, but without a relevance component:

- **Recency**: `exp(-lambda * hours_since_last_access)` -- how recently the node was used
- **Frequency**: `max(base_floor, count / (count + k))` -- how often it's been accessed
- **Reward**: `1 / (1 + exp(-beta * avg_reward))` -- quality signal from trajectory returns

Nodes that are old, rarely accessed, and from low-reward trajectories score low and get pruned.

### When to Run

Run decay periodically to prevent unbounded graph growth. The right frequency depends on your use case:
- **High-throughput agents**: run after every N sessions or on a timer
- **Low-throughput agents**: run weekly or when graph size exceeds a threshold

### Tuning Parameters

```elixir
# More aggressive pruning
Mnemosyne.decay_nodes("my-repo", threshold: 0.2)

# Only prune semantic nodes
Mnemosyne.decay_nodes("my-repo", node_types: [:semantic])
```

The scoring parameters (lambda, k, base_floor, beta) come from the per-type value function config in `Mnemosyne.Config`.

## Orphan Cleanup

Both operations automatically clean up orphaned routing nodes (Tags and Intents) that have no remaining children after deletion. You don't need to handle this manually.

## Combining Operations

A typical maintenance routine:

```elixir
defmodule MyApp.MemoryMaintenance do
  def run(repo_id) do
    # First consolidate duplicates
    {:ok, consolidation} = Mnemosyne.consolidate_semantics(repo_id)

    # Then prune low-value nodes
    {:ok, decay} = Mnemosyne.decay_nodes(repo_id)

    %{
      consolidated: consolidation.deleted,
      decayed: decay.deleted,
      checked: consolidation.checked + decay.checked
    }
  end
end
```

Run consolidation before decay -- consolidation may delete nodes that would otherwise survive decay individually but are redundant.

## Next Steps

- [Core Concepts](core-concepts.md) - understand node types and the graph structure
- [Retrieval and Recall](retrieval-and-recall.md) - how value functions score nodes during recall
- [Custom Backends](custom-backends.md) - backends may optimize these operations differently
