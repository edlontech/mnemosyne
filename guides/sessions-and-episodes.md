# Sessions and Episodes

Sessions are the write interface to the knowledge graph. This guide covers the session state machine, episode lifecycle, and extraction pipeline.

## Session State Machine

A session is a `GenStateMachine` process that manages the episode lifecycle. It follows this state diagram:

```
[*] --> idle
idle --> collecting     : start_episode
collecting --> extracting : close
extracting --> ready     : extraction success
extracting --> failed    : extraction error
ready --> idle           : commit
failed --> extracting    : commit (retry)
failed --> idle          : discard
ready --> idle           : discard
```

### States

| State | Description |
|-------|-------------|
| `:idle` | No active episode. Ready to start one. |
| `:collecting` | Accepting observation-action pairs via `append/3`. |
| `:extracting` | Episode closed, LLM extraction running asynchronously. |
| `:ready` | Extraction complete, changeset available for commit. |
| `:failed` | Extraction failed, episode preserved for retry. |

## Starting a Session

Sessions are created via `Mnemosyne.start_session/2` and immediately enter the `:collecting` state with an open episode:

```elixir
{:ok, session_id} = Mnemosyne.start_session("Explore caching strategies", repo: "my-repo")
```

The goal string describes the high-level objective. It's used by the LLM during subgoal inference and state summarization.

Sessions inherit LLM, embedding, and config defaults from their repo's MemoryStore. You can override any of these per-session:

```elixir
{:ok, session_id} = Mnemosyne.start_session("Debug auth flow",
  repo: "my-repo",
  config: %Mnemosyne.Config{
    llm: %{model: "claude-sonnet-4-20250514", opts: %{}},
    embedding: %{model: "text-embedding-3-small", opts: %{}}
  })
```

## Appending Observations

While in the `:collecting` state, feed observation-action pairs:

```elixir
:ok = Mnemosyne.append(session_id, "User asked about GenServer timeouts", "Explained timeout options")
:ok = Mnemosyne.append(session_id, "User wants to handle crashes gracefully", "Suggested supervisor strategies")
```

Each `append/3` call:
1. Creates a new step in the current episode
2. Uses the LLM to infer a subgoal, reward, and state summary for the step
3. Embeds the inferred subgoal using the configured embedding adapter
4. Compares the subgoal embedding with the previous trajectory's subgoal embedding
5. If similarity drops below the threshold (0.75), starts a new trajectory

The 60-second timeout on `append/3` accounts for LLM latency during step annotation.

### Trajectory Boundaries

Trajectories are detected automatically. When the agent's focus shifts (e.g., from discussing caching to discussing authentication), the embedding similarity between consecutive observations drops, and a new trajectory begins.

Each trajectory gets its own knowledge extraction pass, producing focused semantic and procedural nodes rather than mixing unrelated topics.

## Closing an Episode

When the interaction is done, close the episode:

```elixir
:ok = Mnemosyne.close(session_id)
```

This triggers asynchronous extraction under a `Task.Supervisor`. The session moves to `:extracting` and remains responsive to state queries while the LLM work happens in the background.

### What Extraction Does

For each trajectory in the episode, the structuring pipeline runs three extraction tasks in parallel:

1. **Semantic extraction** - distills factual propositions with concepts and confidence scores
2. **Procedural extraction** - abstracts reusable instructions with conditions and outcomes
3. **Return computation** - evaluates trajectory quality via cumulative reward

The results are merged into a single `Changeset` containing all new nodes and links. The pipeline also:
- Creates `Tag` nodes as concept indices, linked to their semantic nodes
- Creates `Intent` nodes as goal abstractions, linked to their procedural nodes
- Deduplicates intents against existing graph nodes via cosine similarity
- Adds sibling links between semantic nodes from the same trajectory

## Committing Results

Once extraction completes (session in `:ready` state), commit the changeset:

```elixir
:ok = Mnemosyne.commit(session_id)
```

This applies the changeset to the repo's MemoryStore, making the new knowledge available for recall. The session returns to `:idle`.

### Close and Commit in One Step

For convenience, `close_and_commit/1` combines closing, waiting for extraction, and committing:

```elixir
:ok = Mnemosyne.close_and_commit(session_id)
```

It polls the session state and handles retries on transient failures:

```elixir
:ok = Mnemosyne.close_and_commit(session_id,
  max_retries: 5,      # retry extraction up to 5 times (default: 2)
  max_polls: 300,       # poll up to 300 times (default: 200)
  poll_interval: 100)   # 100ms between polls (default: 50ms)
```

## Async Operations and Queuing

The sync API (`commit/1`, `close/1`, etc.) rejects operations when the session is busy. The async API enqueues them instead, executing when the blocking work completes:

```elixir
:ok = Mnemosyne.close(session_id)

# Instead of polling for :ready, queue the commit immediately:
:ok = Mnemosyne.commit_async(session_id, fn
  {:ok, :committed} -> IO.puts("committed")
  {:error, reason} -> IO.puts("failed: #{inspect(reason)}")
end)
```

The callback is optional. Without it, the operation is fire-and-forget:

```elixir
:ok = Mnemosyne.commit_async(session_id)
```

You can chain operations. Each is validated against the projected state after all preceding queued ops:

```elixir
:ok = Mnemosyne.close(session_id)
:ok = Mnemosyne.commit_async(session_id)
:ok = Mnemosyne.start_episode_async(session_id, "Next goal")
# Session will: finish extraction → commit → start new episode
```

### Available Async Functions

| Function | Queues when |
|----------|------------|
| `commit_async/2` | `:extracting` or `:collecting` with in-flight trajectory tasks |
| `discard_async/2` | Same |
| `start_episode_async/3` | Same |
| `close_async/2` | Same |

When the session is not busy, async functions execute immediately (same as their sync counterparts).

### Queuing Rules

- Maximum 5 pending operations
- Each operation is validated against the projected state (e.g., can't queue two commits in a row)
- `:ok` return means "accepted for execution", not "guaranteed to succeed"
- If extraction fails, all queued callbacks receive `{:error, %SessionError{reason: :extraction_failed}}`
- If a queued operation fails during drain, subsequent callbacks receive `{:error, %SessionError{reason: :preceding_op_failed}}`

### Auto-commit Sessions

With auto-commit enabled, extraction success transitions directly to `:idle` (skipping `:ready`). The async API accounts for this — `commit_async` is invalid (already auto-committed), but `start_episode_async` works:

```elixir
# Auto-commit session: queue a new episode after extraction
:ok = Mnemosyne.close(session_id)
:ok = Mnemosyne.start_episode_async(session_id, "Next goal")
```

## Handling Failures

If extraction fails, the session moves to `:failed`. The closed episode is preserved, so you can retry:

```elixir
# Retry extraction
:ok = Mnemosyne.commit(session_id)  # in :failed state, this retries extraction
```

Or discard the episode entirely:

```elixir
:ok = Mnemosyne.discard(session_id)
```

## Checking Session State

Query the current state at any time:

```elixir
state = Mnemosyne.session_state(session_id)
# => :idle | :collecting | :extracting | :ready | :failed
```

## Session Context for Recall

Active sessions carry context (goal, recent steps) that can augment recall queries:

```elixir
{:ok, memories} = Mnemosyne.recall_in_context("my-repo", session_id, "What patterns apply here?")
```

The session provides its current goal and recent steps. The retrieval pipeline uses the last 3 steps to augment the query for more targeted results.

## Next Steps

- [Core Concepts](core-concepts.md) - the mental model behind episodes and trajectories
- [Retrieval and Recall](retrieval-and-recall.md) - how to query the knowledge graph
- [Graph Maintenance](graph-maintenance.md) - keeping the graph clean over time
