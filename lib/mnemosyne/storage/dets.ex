defmodule Mnemosyne.Storage.DETS do
  @moduledoc """
  DETS-backed storage for the knowledge graph.

  Stores nodes as flat `{node_id, node_struct}` records in a single DETS table.
  Secondary indexes are rebuilt on load via `Graph.put_node/2`.
  """
  @behaviour Mnemosyne.Storage

  alias Mnemosyne.Errors.Framework.StorageError
  alias Mnemosyne.Graph
  alias Mnemosyne.Graph.Node, as: NodeProtocol

  @default_path "mnemosyne.dets"

  @impl true
  def init(opts) do
    path = opts |> Keyword.get(:path, @default_path) |> String.to_charlist()

    case :dets.open_file(path, type: :set, auto_save: 60_000) do
      {:ok, ref} -> {:ok, %{ref: ref, path: path}}
      {:error, reason} -> {:error, StorageError.exception(operation: :init, reason: reason)}
    end
  end

  @impl true
  def load_graph(%{ref: ref}) do
    graph =
      :dets.foldl(
        fn {_id, node}, acc -> Graph.put_node(acc, node) end,
        Graph.new(),
        ref
      )

    {:ok, graph}
  rescue
    e -> {:error, StorageError.exception(operation: :load_graph, reason: e)}
  end

  @impl true
  def persist_changeset(changeset, %{ref: ref}) do
    with :ok <- insert_nodes(changeset.additions, ref),
         :ok <- persist_links(changeset.links, ref),
         :ok <- :dets.sync(ref) do
      :ok
    else
      {:error, reason} ->
        {:error, StorageError.exception(operation: :persist_changeset, reason: reason)}
    end
  end

  @impl true
  def delete_nodes(node_ids, %{ref: ref}) do
    with :ok <- do_delete_nodes(node_ids, ref),
         :ok <- :dets.sync(ref) do
      :ok
    else
      {:error, reason} ->
        {:error, StorageError.exception(operation: :delete_nodes, reason: reason)}
    end
  end

  defp insert_nodes(additions, ref) do
    Enum.reduce_while(additions, :ok, fn node, :ok ->
      id = NodeProtocol.id(node)

      case :dets.insert(ref, {id, node}) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp persist_links(links, ref) do
    Enum.reduce_while(links, :ok, fn {id_a, id_b}, :ok ->
      with :ok <- update_link(ref, id_a, id_b),
           :ok <- update_link(ref, id_b, id_a) do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp update_link(ref, node_id, linked_id) do
    case :dets.lookup(ref, node_id) do
      [{^node_id, node}] ->
        updated = %{node | links: MapSet.put(node.links, linked_id)}
        :dets.insert(ref, {node_id, updated})

      [] ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  defp do_delete_nodes(node_ids, ref) do
    Enum.reduce_while(node_ids, :ok, fn id, :ok ->
      case :dets.delete(ref, id) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
