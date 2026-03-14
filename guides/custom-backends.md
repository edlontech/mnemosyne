# Custom Backends

The `GraphBackend` behaviour abstracts graph persistence and querying behind a unified interface. This guide walks through implementing a custom backend.

## The GraphBackend Behaviour

Your backend module must implement 10 callbacks:

```elixir
defmodule MyApp.PostgresBackend do
  @behaviour Mnemosyne.GraphBackend

  # ...
end
```

### Initialization

```elixir
@callback init(opts :: keyword()) :: {:ok, state()} | {:error, error()}
```

Called once when the repo is opened. Set up connections, load state, and return your backend state. This state is threaded through all subsequent calls.

```elixir
@impl true
def init(opts) do
  repo = Keyword.fetch!(opts, :repo)
  table = Keyword.get(opts, :table, "mnemosyne_nodes")
  {:ok, %{repo: repo, table: table}}
end
```

### Mutations

```elixir
@callback apply_changeset(Changeset.t(), state()) :: {:ok, state()} | {:error, error()}
@callback delete_nodes([String.t()], state()) :: {:ok, state()} | {:error, error()}
```

`apply_changeset/2` receives a `%Changeset{}` containing nodes and links to add. The changeset has:
- `nodes` - a list of node structs implementing the `Node` protocol
- `links` - a list of `{source_id, target_id}` tuples

`delete_nodes/2` removes nodes by their IDs and any links referencing them.

```elixir
@impl true
def apply_changeset(changeset, state) do
  Enum.each(changeset.nodes, fn node ->
    insert_node(state, node)
  end)

  Enum.each(changeset.links, fn {source_id, target_id} ->
    insert_link(state, source_id, target_id)
  end)

  {:ok, state}
end
```

### Candidate Search

```elixir
@callback find_candidates(
            node_types :: [atom()],
            query_embedding :: [float()],
            tag_embeddings :: [[float()]],
            value_fn_config :: %{module: module(), params: %{atom() => map()}},
            opts :: keyword(),
            state()
          ) :: {:ok, [scored_node()], state()} | {:error, error()}
```

This is the core retrieval callback. It must:
1. Find nodes matching the given types
2. Compute relevance using the query and tag embeddings
3. Score candidates using the provided value function module and params
4. Return `{node, score}` tuples, respecting per-type thresholds and top_k limits

The `value_fn_config` map contains:
- `:module` - the ValueFunction implementation to call
- `:params` - per-node-type parameter maps (threshold, top_k, lambda, k, base_floor, beta)

For a Postgres + pgvector backend, you'd push similarity search to the database:

```elixir
@impl true
def find_candidates(node_types, query_vector, tag_vectors, vf_config, _opts, state) do
  vf_module = Map.get(vf_config, :module, Mnemosyne.ValueFunction.Default)

  candidates =
    Enum.flat_map(node_types, fn type ->
      params = get_in(vf_config, [:params, type]) || %{}
      top_k = Map.get(params, :top_k, 20)
      threshold = Map.get(params, :threshold, 0.0)

      # Push vector search to Postgres
      nodes = query_similar_nodes(state, type, query_vector, tag_vectors, top_k * 2)

      # Score with value function
      nodes
      |> Enum.map(fn {node, relevance, metadata} ->
        score = vf_module.score(relevance, node, metadata, params)
        {node, score}
      end)
      |> Enum.filter(fn {_, score} -> score >= threshold end)
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.take(top_k)
    end)

  {:ok, candidates, state}
end
```

### Node Retrieval

```elixir
@callback get_node(String.t(), state()) :: {:ok, struct() | nil, state()}
@callback get_linked_nodes([String.t()], state()) :: {:ok, [struct()], state()}
@callback get_nodes_by_type(node_types :: [atom()], state()) :: {:ok, [struct()], state()}
```

These support multi-hop traversal and maintenance operations. `get_linked_nodes/2` fetches nodes by a list of IDs (filtering out any that don't exist). `get_nodes_by_type/2` returns all nodes of the given types.

### Metadata Operations

```elixir
@callback get_metadata([String.t()], state()) :: {:ok, %{String.t() => struct()}, state()}
@callback update_metadata(%{String.t() => struct()}, state()) :: {:ok, state()}
@callback delete_metadata([String.t()], state()) :: {:ok, state()}
```

Metadata (`NodeMetadata` structs) tracks per-node usage statistics separately from node content. The metadata map is keyed by node ID.

## State Threading

All callbacks receive and return the backend state. Read callbacks (`find_candidates`, `get_node`, `get_linked_nodes`, etc.) return state for interface uniformity, but callers may discard the returned state in read-only contexts. Don't rely on side effects in the returned state from read operations.

## Registering Your Backend

Pass your backend when opening a repo:

```elixir
{:ok, _pid} = Mnemosyne.open_repo("my-project",
  backend: {MyApp.PostgresBackend, repo: MyApp.Repo, table: "knowledge_nodes"})
```

The second element of the tuple is passed as `opts` to `init/1`.

## Testing

Test your backend against the same operations the InMemory backend handles. The test suite in `test/mnemosyne/memory_store_test.exs` exercises the full backend interface through the MemoryStore.

Key scenarios to cover:
- Apply a changeset, then retrieve nodes by ID and type
- Delete nodes and verify links are cleaned up
- Find candidates with various embedding vectors
- Metadata CRUD operations
- Concurrent access patterns

## Reference Implementation

See `lib/mnemosyne/graph_backends/in_memory.ex` for the complete InMemory implementation. It wraps a `Graph` struct and uses `Similarity.cosine_similarity/2` for relevance scoring.

## Next Steps

- [Custom Adapters](custom-adapters.md) - writing LLM and embedding adapters
- [Retrieval and Recall](retrieval-and-recall.md) - how the retrieval pipeline uses your backend
- [Graph Maintenance](graph-maintenance.md) - maintenance operations that call your backend
