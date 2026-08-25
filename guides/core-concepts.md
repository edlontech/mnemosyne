# Core Concepts

Mnemosyne models agent memory as a knowledge graph built from reinforcement-learning primitives.

## The Three Memory Types

### Episodic Memory

Episodic nodes are ordered records of observation, action, inferred state, subgoal, and reward. They preserve what happened and provide evidence for extracted knowledge.

### Semantic Memory

Semantic nodes store factual propositions distilled from experience. Each carries a proposition, confidence, and embedding. Concept labels become **Tag** nodes that route retrieval among related facts.

### Procedural Memory

Procedural nodes store reusable instructions with conditions and expected outcomes. Inferred labels become **Intent** nodes that route retrieval among related procedures.

## Complete Trajectories and Internal Episodes

The public write primitive is a complete `%Mnemosyne.Trajectory{}` containing a repo-scoped stable source ID, a goal, ordered raw steps, and metadata. The caller owns the history until it submits it through blocking `Mnemosyne.ingest/3`.

```elixir
trajectory = %Mnemosyne.Trajectory{
  source_id: "task-42",
  goal: "Diagnose a cache miss",
  steps: [
    %{observation: "The key was absent", action: "Inspected cache population"},
    %{observation: "Population used another namespace", action: "Aligned the namespace"}
  ],
  metadata: %{component: "cache"}
}

{:ok, receipt} = Mnemosyne.ingest("my-repo", trajectory)
```

Ingestion constructs an internal **episode** from the complete input. As each step is annotated, embedding similarity detects coherent **extraction trajectories** within that episode. Knowledge extraction runs per coherent segment so unrelated topics are not combined. Source provenance uses the caller's source ID.

Neither an episode nor an extraction trajectory is caller-visible lifecycle state. Mnemosyne returns only after the final changeset and source ingestion record are committed.

## The Knowledge Graph

| Node Type | Role |
|-----------|------|
| **Episodic** | Raw observation-action-reward tuples |
| **Semantic** | Factual propositions |
| **Procedural** | Goal-directed instructions |
| **Subgoal** | Decomposed objectives linking related knowledge |
| **Source** | Provenance links to original episode steps |
| **Tag** | Concept indices for semantic nodes |
| **Intent** | Goal abstractions for procedural nodes |

Nodes are connected by typed links and indexed for retrieval. Tags and Intents are routing nodes: they connect knowledge but do not carry the knowledge themselves.

## Value Functions

Every knowledge node has metadata for recency, access frequency, and cumulative reward. Retrieval combines those signals with embedding relevance:

```
score = relevance * recency_factor * frequency_factor * reward_factor
```

Frequently used, recent, high-quality knowledge can therefore rank above a similarly relevant but stale node.

## Changesets and Ingestion Records

Extraction produces a `%Mnemosyne.Graph.Changeset{}` containing node additions, typed links, and node metadata. The backend's ingestion compare-and-set is the authoritative write boundary: it stores graph changes and a source record together, returns an existing receipt for an equal payload, or rejects a conflict.

Ingestion records are control data outside the graph. Graph deletion and decay do not remove them, so retrying a source whose nodes were removed returns the original receipt instead of recreating memory.

## Graph Backends

`Mnemosyne.GraphBackend` abstracts persistence and queries. The built-in `InMemory` backend stores graph state in Erlang maps and can persist it with DETS. A custom backend must also implement durable source lookup and compare-and-set ingestion.

## Next Steps

- [Trajectory Ingestion](trajectory-ingestion.md)
- [Extraction Profiles](extraction-profiles.md)
- [Retrieval and Recall](retrieval-and-recall.md)
- [Custom Backends](custom-backends.md)
