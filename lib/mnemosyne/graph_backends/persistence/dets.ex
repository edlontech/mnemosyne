defmodule Mnemosyne.GraphBackends.Persistence.DETS do
  @moduledoc """
  DETS-backed persistence for the InMemory graph backend.

  Stores nodes as `{node_id, node_struct}` records. Secondary indexes
  are rebuilt on load via `Graph.put_node/2`.
  """

  alias Mnemosyne.Graph
  alias Mnemosyne.Graph.Node, as: NodeProtocol

  @default_path "mnemosyne.dets"

  @doc "Opens the DETS file at the configured path, returning a handle map."
  @spec init(keyword()) :: {:ok, map()} | {:error, term()}
  def init(opts) do
    path = opts |> Keyword.get(:path, @default_path) |> String.to_charlist()

    case :dets.open_file(path, type: :set, auto_save: 60_000) do
      {:ok, ref} -> {:ok, %{ref: ref, path: path}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Reads all records from DETS and rebuilds a `Graph` struct plus metadata map.

  Node records are stored as `{id, node}` tuples, metadata records as
  `{{:meta, id}, metadata}` tuples. Both are separated during the fold.
  """
  @spec load(map()) :: {:ok, Graph.t(), map()} | {:error, term()}
  def load(%{ref: ref}) do
    {graph, metadata} =
      :dets.foldl(
        fn
          {{:meta, id}, meta}, {g, m} -> {g, Map.put(m, id, meta)}
          {_id, node}, {g, m} -> {Graph.put_node(g, node), m}
        end,
        {Graph.new(), %{}},
        ref
      )

    {:ok, graph, metadata}
  rescue
    e -> {:error, e}
  end

  @doc "Persists changeset additions and links to DETS."
  @spec save(Mnemosyne.Graph.Changeset.t(), map()) :: :ok | {:error, term()}
  def save(changeset, %{ref: ref}) do
    with :ok <- insert_nodes(changeset.additions, ref),
         :ok <- persist_links(changeset.links, ref) do
      :dets.sync(ref)
    end
  end

  @doc "Removes nodes by ID from DETS."
  @spec delete([String.t()], map()) :: :ok | {:error, term()}
  def delete(node_ids, %{ref: ref}) do
    with :ok <- do_delete_nodes(node_ids, ref) do
      :dets.sync(ref)
    end
  end

  @doc "Persists metadata entries as `{{:meta, id}, metadata}` records."
  @spec save_metadata(%{String.t() => struct()}, map()) :: :ok | {:error, term()}
  def save_metadata(entries, %{ref: ref}) do
    result =
      Enum.reduce_while(entries, :ok, fn {id, meta}, :ok ->
        case :dets.insert(ref, {{:meta, id}, meta}) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)

    with :ok <- result, do: :dets.sync(ref)
  end

  @doc "Removes metadata entries by node ID from DETS."
  @spec delete_metadata([String.t()], map()) :: :ok | {:error, term()}
  def delete_metadata(node_ids, %{ref: ref}) do
    result =
      Enum.reduce_while(node_ids, :ok, fn id, :ok ->
        case :dets.delete(ref, {:meta, id}) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)

    with :ok <- result, do: :dets.sync(ref)
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
    Enum.reduce_while(links, :ok, fn {id_a, id_b, type}, :ok ->
      with :ok <- update_link(ref, id_a, id_b, type),
           :ok <- update_link(ref, id_b, id_a, type) do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp update_link(ref, node_id, linked_id, type) do
    case :dets.lookup(ref, node_id) do
      [{^node_id, node}] ->
        updated_links =
          Map.update(node.links, type, MapSet.new([linked_id]), &MapSet.put(&1, linked_id))

        updated = %{node | links: updated_links}
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
