# Custom Backends

`Mnemosyne.GraphBackend` is the repository's persistence and query boundary. A custom backend must preserve graph semantics and durable source-idempotency semantics.

## Behaviour Contract

Backend state is initialized once and threaded through callbacks:

```elixir
@callback init(keyword()) ::
  {:ok, state()} | {:error, Mnemosyne.Errors.error()}

@callback apply_changeset(Mnemosyne.Graph.Changeset.t(), state()) ::
  {:ok, state()} | {:error, Mnemosyne.Errors.error()}

@callback delete_nodes([String.t()], state()) ::
  {:ok, state()} | {:error, Mnemosyne.Errors.error()}
```

A changeset contains `additions`, typed `links` shaped as `{source_id, target_id, edge_type}`, and node `metadata`. Deletion removes the requested graph nodes and their dangling links, but must not remove ingestion records.

The query callbacks are:

```elixir
@callback find_candidates(
  [atom()],
  [float()],
  [[float()]],
  %{module: module(), params: %{atom() => map()}},
  keyword(),
  state()
) :: {:ok, [{struct(), float()}], state()} | {:error, Mnemosyne.Errors.error()}

@callback get_node(String.t(), state()) ::
  {:ok, struct() | nil, state()}

@callback get_linked_nodes([String.t()], Mnemosyne.Graph.Edge.edge_type() | nil, state()) ::
  {:ok, [struct()], state()}

@callback get_nodes_by_type([atom()], state()) ::
  {:ok, [struct()], state()} | {:error, Mnemosyne.Errors.error()}

@callback get_metadata([String.t()], state()) ::
  {:ok, %{String.t() => struct()}, state()}

@callback update_metadata(%{String.t() => struct()}, state()) ::
  {:ok, state()}

@callback delete_metadata([String.t()], state()) ::
  {:ok, state()}
```

`find_candidates/6` must derive relevance from the query embedding and tag embeddings, score with the configured value-function module and per-type parameters, then enforce each type's threshold and `top_k`. Read callbacks return state for interface uniformity, but callers may discard that returned state. Do not require read-side state mutation for correctness.

## Durable Ingestion Records

The record type is:

```elixir
@type ingestion_record :: %{
        source_id: String.t(),
        payload_digest: binary(),
        fingerprint_version: pos_integer(),
        receipt: Mnemosyne.IngestionReceipt.t()
      }
```

Its callbacks and exact results are:

```elixir
@callback get_ingestion(String.t(), state()) ::
  {:ok, Mnemosyne.GraphBackend.ingestion_record() | nil, state()}
  | {:error, Mnemosyne.Errors.error()}

@callback commit_ingestion(
  Mnemosyne.GraphBackend.ingestion_record(),
  Mnemosyne.Graph.Changeset.t(),
  state()
) ::
  {:ok, :inserted | :existing, Mnemosyne.IngestionReceipt.t(), state()}
  | {:error, Mnemosyne.Errors.error()}
```

`commit_ingestion/3` is the authoritative compare-and-set:

- If the source ID is absent, atomically commit the changeset additions, typed links, node metadata, and ingestion record, then return `{:ok, :inserted, receipt, state}`.
- If the stored `fingerprint_version` and `payload_digest` both match, discard the supplied changeset and return the exact stored receipt as `{:ok, :existing, receipt, state}`.
- If either differs, change nothing and return `%Mnemosyne.Errors.Invalid.IngestionError{reason: :source_conflict}`.

The returned receipt is authoritative. This final check must remain correct when multiple Mnemosyne processes reach a shared backend concurrently; an application-side lookup is not sufficient.

Ingestion records are permanent control records outside graph nodes. `delete_nodes/2`, decay, consolidation, and graph repair must not remove them. Consequently, retrying a source after its graph nodes were deleted returns the original receipt and does not recreate those nodes.

## Payload Fingerprint

Current payload identity is SHA-256 over deterministic Erlang external term format for this exact tuple:

```elixir
{:mnemosyne_trajectory, 1, goal, ordered_step_tuples, metadata}
```

`ordered_step_tuples` contains `{observation, action}` in caller order. The source ID selects the repo-scoped record but is not inside the digest. Encoding uses `:erlang.term_to_binary/2` with `:deterministic` and fixed `minor_version: 2`; every record stores `fingerprint_version: 1`.

This identity is deterministic for the supported Elixir terms in the intended OTP runtime, not a portable cross-language format. Erlang only gives bounded compatibility guarantees for deterministic encoding across OTP runtimes; a major runtime change can require deliberate fingerprint data handling. Never treat a different fingerprint version as equal.

## Built-in DETS Limitation

The built-in InMemory transition is atomic when persistence is disabled. Its DETS adapter has no transaction, rollback, or write-ahead log. For a new ingestion it writes, in order:

1. graph node rows;
2. link updates;
3. node metadata rows;
4. `{{:ingestion, source_id}, record}` last as the commit marker;
5. `:dets.sync/1`.

A failure before or during completion can leave partial graph, link, or metadata rows because DETS cannot roll them back. The operation must not return success unless the ingestion marker was written and synchronization succeeded. The marker-last order prevents a markerless partial write from being reported as a successful ingestion.

Custom database backends should use their native transaction and uniqueness/compare-and-set facilities to make the graph mutation and ingestion record one logical commit.

## Registration and Testing

```elixir
defmodule MyApp.PostgresBackend do
  @behaviour Mnemosyne.GraphBackend

  # Implement every callback above.
end

{:ok, _pid} =
  Mnemosyne.open_repo("my-project",
    backend: {MyApp.PostgresBackend, repo: MyApp.Repo}
  )
```

At minimum, test absent, equal, and conflicting ingestion commits; simultaneous commits for one source; exact receipt persistence across restart; graph and metadata visibility before success; and ingestion-record survival after deletion and decay. Also cover candidate scoring, typed traversal, metadata operations, and dangling-link cleanup.

See `Mnemosyne.GraphBackends.InMemory` for the reference implementation.
