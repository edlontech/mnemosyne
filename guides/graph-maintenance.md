# Graph Maintenance

Mnemosyne provides explicit operations for merging near-duplicate semantic knowledge and pruning low-utility graph nodes.

## Semantic Consolidation

```elixir
:ok = Mnemosyne.consolidate_semantics("my-repo")
```

Consolidation finds semantic nodes connected through shared Tags, compares embeddings, and asks the LLM whether the strongest candidate pair should merge. The higher decay-scored node survives; accepted merged content is re-embedded, links and metadata transfer, and the redundant node is deleted.

The default similarity threshold is `0.7`. Raise it to reduce LLM calls:

```elixir
:ok = Mnemosyne.consolidate_semantics("my-repo", threshold: 0.85)
```

Run consolidation after large ingestion batches that may contain overlapping facts.

## Node Decay

```elixir
:ok = Mnemosyne.decay_nodes("my-repo")
```

Decay scores the selected node types using recency, frequency, and reward without query relevance:

```
score = recency_factor * frequency_factor * reward_factor
```

Nodes below the threshold are deleted, then orphaned Tag and Intent routing nodes are cleaned up.

```elixir
# More aggressive pruning
:ok = Mnemosyne.decay_nodes("my-repo", threshold: 0.2)

# Only semantic nodes
:ok = Mnemosyne.decay_nodes("my-repo", node_types: [:semantic])
```

The scoring parameters (`lambda`, `k`, `base_floor`, and `beta`) come from each node type's value-function config.

## Permanent Source Identity

Maintenance changes graph content only. Ingestion records are permanent control records outside the graph, so consolidation, decay, direct node deletion, and graph repair do not clear a source ID.

If maintenance removes nodes listed in an ingestion receipt, submitting the same repo-scoped source and payload again returns the exact original receipt. It does not recreate the removed memory. Reusing that source ID with a different payload still returns a source-conflict error.

## Operational Ordering

Each repository has one non-queued maintenance slot. If consolidation and decay are requested back to back, the second request is dropped while the first is active.

When both are needed, run consolidation first and trigger decay only after receiving its `:consolidation_completed` notifier outcome. Otherwise, invoke decay manually later. Mnemosyne does not schedule maintenance operations.

## Next Steps

- [Core Concepts](core-concepts.md)
- [Retrieval and Recall](retrieval-and-recall.md)
- [Custom Backends](custom-backends.md)
- [Notifier](notifier.md)
