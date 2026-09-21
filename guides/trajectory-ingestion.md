# Trajectory Ingestion

Mnemosyne's write boundary is a complete, caller-owned `%Mnemosyne.Trajectory{}` submitted through blocking `Mnemosyne.ingest/3`. Mnemosyne does not own unfinished interaction state.

## Complete Input

```elixir
trajectory = %Mnemosyne.Trajectory{
  source_id: "support-ticket-1842",
  goal: "Resolve an intermittent authentication failure",
  steps: [
    %{
      observation: "Login succeeds locally but fails in production",
      action: "Compared environment configuration"
    },
    %{
      observation: "The production callback URL uses HTTP",
      action: "Changed the callback URL to HTTPS"
    }
  ],
  metadata: %{tenant: "acme", workflow_version: 3}
}

{:ok, %Mnemosyne.IngestionReceipt{} = receipt} =
  Mnemosyne.ingest("support", trajectory)
```

`source_id` and `goal` must be non-blank binaries. `steps` must contain at least one observation/action map, in execution order, with binary values. Metadata must be a map composed of deterministic plain terms; PIDs, ports, references, functions, and containers holding them are rejected.

The pipeline creates an internal episode identified by `source_id`, annotates each step in order, scores the final step, closes the episode, and extracts a graph changeset. Source provenance therefore carries the caller's source ID.

## Custom Node Metadata

The trajectory's `metadata` map is copied into `Mnemosyne.NodeMetadata.custom` for every extracted node. It defaults to `%{}` and is stored separately from node content and internal scoring fields. Mnemosyne does not use this map for recall filtering, ranking, embeddings, authorization, or LLM prompts.

Read it through the existing metadata API:

```elixir
{:ok, metadata_by_id} = Mnemosyne.get_metadata("support", receipt.node_ids)

Enum.each(metadata_by_id, fn {node_id, metadata} ->
  IO.inspect({node_id, metadata.custom})
end)
```

For recalled memories, pass `Enum.map(memories.touched_nodes, & &1.id)` to the same API. Protected repositories require the usual `authorization:` option.

Custom metadata survives persistence, access-count updates, and node merges. Tag deduplication, intent merging, and semantic consolidation combine maps shallowly: the surviving node's value wins for duplicate keys, including nested maps. Existing DETS records without this field load with `%{}`; past trajectory metadata is not backfilled.

Metadata remains part of ingestion payload identity. Changing it while reusing a stored `source_id` returns a source-conflict error rather than updating the existing memory.

## Blocking Stored-or-Error Boundary

`ingest/3` blocks across validation, LLM and embedding work, final graph serialization, and backend commit. `{:ok, receipt}` means the ingestion record is stored and the receipt's `node_ids` are immediately query-visible. There is no accepted-but-pending success state.

An error means the caller should decide whether and when to retry. Applications retain unfinished observations, recovery policy, and concurrency control. A caller exiting does not cancel work shared with another waiter; repo shutdown before commit can interrupt the operation, and a later caller may retry the complete trajectory.

## Repo-Scoped Source Identity

A source ID names one payload within one repository. The same source ID may be used independently in another repo.

The payload fingerprint is based on the goal, ordered observation/action pairs, and metadata. For a source ID:

- an equal stored payload returns the exact original `%IngestionReceipt{}`, including its original `node_ids` and `stored_at`;
- a different payload or fingerprint version returns `%Mnemosyne.Errors.Invalid.IngestionError{reason: :source_conflict}` and does not replace memory;
- equal calls while the source is pending coalesce into one extraction and all waiters receive the authoritative receipt;
- a different pending payload conflicts immediately.

Ingestion records are permanent source-identity records outside the graph. Deleting or decaying graph nodes does not clear them. Retrying such a source returns the original receipt and does not reconstruct removed nodes.

## Execution Overrides

Execution can be changed per call:

```elixir
Mnemosyne.ingest("support", trajectory,
  config: research_config,
  llm: MyApp.PreciseLLM,
  embedding: MyApp.Embedding,
  llm_opts: [temperature: 0.0]
)
```

The replacement config controls ordinary trajectory embedding calls, and `llm_opts` flows through ingestion LLM stages where used. Per-call `embedding_opts` currently reaches only write-time intent merging. Execution options do not enter payload identity. The first admitted call owns execution for coalesced work; later equal callers' overrides are ignored, and an equal stored retry returns the original receipt without rerunning adapters.

## Recall During Active Work

Keep active context with the caller and pass it transiently to `recall/3`:

```elixir
{:ok, memories} =
  Mnemosyne.recall("support", "What should I investigate next?",
    source_id: "support-ticket-1843",
    context: %{
      goal: "Resolve an intermittent authentication failure",
      recent_steps: [
        %{
          observation: "Tokens expire only behind the proxy",
          action: "Inspected forwarded headers"
        }
      ]
    }
  )
```

The goal and at most the last three recent steps augment retrieval and reasoning. Context is not persisted and does not reserve `source_id`; the optional source ID only correlates telemetry, notifier metadata, and traces.

## Related Guides

- [Getting Started](getting-started.md)
- [Retrieval and Recall](retrieval-and-recall.md)
- [Custom Backends](custom-backends.md)
- [Notifier](notifier.md)
