# Notifier -- Real-Time Events

`Mnemosyne.Notifier` delivers graph, ingestion, recall, and maintenance outcomes to an application adapter without adding a messaging dependency.

## Behaviour and Configuration

```elixir
@callback notify(repo_id :: String.t(), Mnemosyne.Notifier.event()) :: :ok
```

A typical adapter forwards events to an existing bus:

```elixir
defmodule MyApp.PubSubNotifier do
  @behaviour Mnemosyne.Notifier

  @impl true
  def notify(repo_id, event) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, "mnemosyne:#{repo_id}", event)
  end
end
```

Configure a shared default on the supervisor or override it when opening a repo:

```elixir
{Mnemosyne.Supervisor,
  config: config,
  llm: MyApp.LLMAdapter,
  embedding: MyApp.EmbeddingAdapter,
  notifier: MyApp.PubSubNotifier}

Mnemosyne.open_repo("special-repo",
  backend: {Mnemosyne.GraphBackends.InMemory, []},
  notifier: MyApp.AuditNotifier
)
```

`Mnemosyne.Notifier.Noop` is the default. The repository ID is always the first argument to `notify/2`, regardless of event shape.

Every adapter call goes through `Mnemosyne.Notifier.safe_notify/3`. Ordinary exceptions, throws, and exits are logged and converted to `:ok`; notifier failure never changes ingestion, recall, or graph-operation results.

## Ingestion Outcomes

```elixir
{:trajectory_ingested, %Mnemosyne.IngestionReceipt{} = receipt,
 %{repo_id: repo_id, source_id: source_id, node_ids: node_ids}}

{:trajectory_ingestion_failed, source_id, reason,
 %{repo_id: repo_id, source_id: source_id}}
```

A newly inserted ingestion emits one authoritative success only after backend commit. Equal pending callers share that event. A late equal backend compare-and-set and a persisted equal retry return the original receipt without another success event.

Equal pending callers also share one extraction, task, merge, or write failure event. By contrast, every pending or stored conflicting call emits its own failure event. Input rejected during trajectory validation, before `MemoryStore` admission, emits no event.

## Event Metadata Matrix

Every event has a metadata map as its final element, but only ingestion duplicates the repository ID from the `notify/2` argument:

| Events | Metadata |
|--------|----------|
| `trajectory_ingested` | `%{repo_id: repo_id, source_id: source_id, node_ids: node_ids}` |
| `trajectory_ingestion_failed` | `%{repo_id: repo_id, source_id: source_id}` |
| `recall_executed` | `%{source_id: source_id, trace: trace}` |
| `recall_failed` | `%{source_id: source_id}` |
| `changeset_applied`, `nodes_deleted` | `%{}` |
| `write_failed`, `write_crashed` | `%{}` |
| `decay_completed`, `consolidation_completed`, `validation_completed`, `repair_completed` | `%{}` |

Recall metadata always has the `source_id` key, whose value is `nil` when omitted from `recall/3`; successful recall also includes its trace. The event tuples are:

```elixir
{:changeset_applied, changeset, metadata}
{:nodes_deleted, node_ids, metadata}
{:recall_executed, query, result, metadata}
{:recall_failed, query, reason, metadata}
{:write_failed, operation, reason, metadata}
{:write_crashed, operation, reason, metadata}
{:decay_completed, summary, metadata}
{:consolidation_completed, summary, metadata}
{:validation_completed, summary, metadata}
{:repair_completed, summary, metadata}
```

## Consumer Example

```elixir
def mount(%{"repo_id" => repo_id}, _session, socket) do
  if connected?(socket) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "mnemosyne:#{repo_id}")
  end

  {:ok, assign(socket, ingestions: [], deleted_node_ids: [])}
end

def handle_info({:trajectory_ingested, receipt, metadata}, socket) do
  ingestion = %{source_id: metadata.source_id, node_ids: receipt.node_ids}
  {:noreply, update(socket, :ingestions, &[ingestion | &1])}
end

def handle_info({:nodes_deleted, ids, %{}}, socket) do
  {:noreply, update(socket, :deleted_node_ids, &(ids ++ &1))}
end

def handle_info(_event, socket), do: {:noreply, socket}
```

Notifications report outcomes; query current graph state with `Mnemosyne.get_node/3`, `get_nodes_by_type/3`, `get_metadata/3`, or `get_linked_nodes/3` when a consumer needs full node data.

## Next Steps

- [Trajectory Ingestion](trajectory-ingestion.md)
- [Retrieval and Recall](retrieval-and-recall.md)
- [Graph Maintenance](graph-maintenance.md)
