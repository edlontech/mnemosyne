# Notifier -- Real-Time Graph Events

Mnemosyne emits events whenever the knowledge graph changes. The `Mnemosyne.Notifier` behaviour lets you plug in a handler for these events, enabling real-time graph visualizations, audit logging, or reactive UIs -- all without pulling Phoenix or any other dependency into Mnemosyne itself.

## The Notifier Behaviour

Implement a single callback:

```elixir
@callback notify(repo_id :: String.t(), event()) :: :ok
```

Every graph mutation, maintenance operation, session transition, and recall is broadcast to the configured notifier with the originating `repo_id`.

## Implementing a Notifier

A typical implementation forwards events to Phoenix.PubSub:

```elixir
defmodule MyApp.PubSubNotifier do
  @behaviour Mnemosyne.Notifier

  @impl true
  def notify(repo_id, event) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, "mnemosyne:#{repo_id}", event)
  end
end
```

The default `Mnemosyne.Notifier.Noop` discards all events silently.

## Configuration

Pass your notifier module when starting the supervisor:

```elixir
{Mnemosyne.Supervisor,
  config: config,
  llm: MyApp.LLMAdapter,
  embedding: MyApp.EmbeddingAdapter,
  notifier: MyApp.PubSubNotifier}
```

The notifier is stored as a shared default and automatically passed to every MemoryStore and Session under that supervisor. You can also override it per-repo or per-session via the `:notifier` option.

All notifier calls are wrapped in `Mnemosyne.Notifier.safe_notify/3`, which rescues exceptions and logs a warning. A failing notifier never crashes the memory pipeline.

## Event Types

| Event | Payload | Emitted by |
|-------|---------|------------|
| `{:changeset_applied, changeset}` | `Mnemosyne.Graph.Changeset` with added/updated nodes | MemoryStore |
| `{:nodes_deleted, node_ids}` | List of deleted node ID strings | MemoryStore |
| `{:decay_completed, summary}` | `%{checked: integer, deleted: integer, deleted_ids: [String.t()]}` | MemoryStore |
| `{:consolidation_completed, summary}` | `%{checked: integer, deleted: integer, deleted_ids: [String.t()]}` | MemoryStore |
| `{:recall_executed, query, results}` | Query string and retrieval results | MemoryStore |
| `{:session_transition, session_id, old_state, new_state}` | State machine transition (e.g. `:idle` to `:collecting`) | Session |

## Query Functions

Notifications tell you *what* changed, but you often need to fetch the current state of specific nodes. Four query functions complement the event stream:

| Function | Purpose |
|----------|---------|
| `Mnemosyne.get_node(repo_id, node_id)` | Fetch a single node by ID |
| `Mnemosyne.get_nodes_by_type(repo_id, types)` | Fetch all nodes of given types |
| `Mnemosyne.get_metadata(repo_id, node_ids)` | Fetch `NodeMetadata` (access count, reward, timestamps) |
| `Mnemosyne.get_linked_nodes(repo_id, node_ids)` | Fetch neighbors of given nodes |

These are read-only operations that go directly to the MemoryStore without emitting notifications themselves.

### Example: Enriching a Changeset Event

```elixir
def handle_info({:changeset_applied, changeset}, socket) do
  node_ids = Enum.map(changeset.nodes, & &1.id)

  {:ok, metadata} = Mnemosyne.get_metadata(socket.assigns.repo_id, node_ids)
  {:ok, neighbors} = Mnemosyne.get_linked_nodes(socket.assigns.repo_id, node_ids)

  {:noreply, assign(socket, nodes: changeset.nodes, metadata: metadata, neighbors: neighbors)}
end
```

## LiveView Consumer Example

A minimal LiveView that subscribes to graph events and displays new nodes:

```elixir
defmodule MyAppWeb.GraphLive do
  use MyAppWeb, :live_view

  @impl true
  def mount(%{"repo_id" => repo_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(MyApp.PubSub, "mnemosyne:#{repo_id}")
    end

    {:ok, assign(socket, repo_id: repo_id, events: [])}
  end

  @impl true
  def handle_info({:changeset_applied, changeset}, socket) do
    added = Enum.map(changeset.nodes, fn node ->
      %{id: node.id, type: node.node_type, label: inspect(node)}
    end)

    {:noreply, update(socket, :events, &(added ++ &1))}
  end

  def handle_info({:nodes_deleted, ids}, socket) do
    {:noreply, update(socket, :events, fn events ->
      Enum.reject(events, &(&1.id in ids))
    end)}
  end

  def handle_info({:session_transition, session_id, _old, new_state}, socket) do
    {:noreply, push_event(socket, "session-update", %{id: session_id, state: new_state})}
  end

  def handle_info(_event, socket), do: {:noreply, socket}
end
```

## Next Steps

- [Core Concepts](core-concepts.md) -- node types and graph structure
- [Graph Maintenance](graph-maintenance.md) -- decay and consolidation events
- [Custom Adapters](custom-adapters.md) -- writing LLM and embedding adapters
