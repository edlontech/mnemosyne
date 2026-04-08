# Core Concepts

Mnemosyne models agent memory as a knowledge graph built from reinforcement-learning primitives. This guide explains the mental model you need before working with the library.

## The Three Memory Types

Mnemosyne draws from cognitive science's distinction between memory systems:

### Episodic Memory

Raw records of experience. Each episode is a sequence of observation-action pairs the agent collected during a session. Episodic nodes store what happened, when, and in what order.

Think of these as a logbook: "User asked about Tokyo, I suggested dates."

### Semantic Memory

Factual knowledge distilled from episodes -- "knowing that." When an episode closes, the structuring pipeline extracts propositions like "The user prefers 2-week trips" or "Tokyo has cherry blossoms in March."

Each semantic node carries:
- A **proposition** (the fact itself)
- A **confidence score**
- An **embedding** for similarity search

During extraction, the LLM also produces concept labels for each fact. These become separate **Tag** nodes linked to the semantic node, acting as concept indices.

### Procedural Memory

Prescriptive knowledge extracted from episodes -- "knowing how." These are reusable instructions with conditions and expected outcomes: "When the user asks about a destination, first check their travel dates."

Each procedural node carries:
- A **condition** (when to apply it)
- An **instruction** (what to do)
- An **expected outcome** (what should happen)

During extraction, the LLM also infers an intent label. This becomes a separate **Intent** node linked to the procedural node, grouping related procedures by goal.

## Episodes and Trajectories

An **episode** is the unit of experience collection. You open one by starting a session, feed it observation-action pairs, and close it when the interaction is done.

Within an episode, Mnemosyne automatically detects **trajectory boundaries** using embedding similarity. When consecutive observations are semantically different enough (cosine similarity drops below 0.75), a new trajectory begins. Each trajectory represents a coherent subsequence of steps that share a common intent.

```
Episode
 |-- Trajectory 1 (steps 1-5, about trip planning)
 |-- Trajectory 2 (steps 6-9, about hotel booking)
 |-- Trajectory 3 (steps 10-12, about visa requirements)
```

Knowledge extraction runs per-trajectory, so the system produces focused, coherent facts and instructions rather than jumbled cross-topic extractions.

Extraction can be further tuned with [extraction profiles](extraction-profiles.md) that steer the LLM toward domain-specific knowledge (e.g., prioritizing error patterns for coding, or factual claims for research).

## The Knowledge Graph

All extracted knowledge lives in a directed graph with seven node types:

| Node Type | Role |
|-----------|------|
| **Episodic** | Raw observation-action-reward tuples |
| **Semantic** | Factual propositions |
| **Procedural** | Goal-directed instructions |
| **Subgoal** | Decomposed objectives linking related knowledge |
| **Source** | Provenance links back to original episode steps |
| **Tag** | Concept indices linking related semantic nodes |
| **Intent** | Goal abstractions linking related procedural nodes |

Nodes are connected by bidirectional links and indexed by type, tag, and subgoal for efficient traversal.

### Routing Nodes

**Tags** and **Intents** are routing nodes -- they don't carry knowledge themselves but connect related knowledge nodes. When you recall memory, the retrieval pipeline hops through routing nodes to discover relevant neighbors:

```
Tag("travel planning") --> Semantic("user prefers 2-week trips")
                       --> Semantic("Tokyo has cherry blossoms in March")
                       --> Semantic("user has a Japan Rail Pass")
```

## Value Functions

Every node accumulates metadata over its lifetime:
- **Recency** -- when it was last accessed
- **Frequency** -- how often it's been accessed
- **Reward** -- cumulative quality signal from trajectory returns

During retrieval, the **value function** combines cosine relevance with these signals to score each node:

```
score = relevance * recency_factor * frequency_factor * reward_factor
```

This means frequently-accessed, recently-used, high-quality knowledge ranks higher than stale, rarely-used nodes -- even if raw embedding similarity is similar.

## Changesets

All mutations to the knowledge graph happen through **changesets** -- batched lists of nodes and links to add. Changesets are applied atomically, so the graph is always in a consistent state.

The structuring pipeline produces a changeset per episode. Sessions hold the changeset in a `:ready` state until you call `commit/1`, at which point it's applied to the graph backend.

## Graph Backends

The `GraphBackend` behaviour abstracts persistence. The built-in `InMemory` backend stores nodes in Erlang maps with optional DETS persistence. Custom backends can push to external databases like Postgres with pgvector.

All backends implement the same 10-callback interface, so switching backends doesn't change application code.

## Next Steps

- [Sessions and Episodes](sessions-and-episodes.md) - the session lifecycle in detail
- [Extraction Profiles](extraction-profiles.md) - domain-specific extraction tuning
- [Retrieval and Recall](retrieval-and-recall.md) - how scoring and multi-hop traversal work
- [Custom Backends](custom-backends.md) - implementing your own graph backend
