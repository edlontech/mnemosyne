defmodule Mnemosyne.Graph do
  @moduledoc """
  Core knowledge graph data structure.

  Stores nodes indexed by ID, type, tag label, and subgoal description.
  Supports bidirectional linking between nodes and batch mutation via changesets.
  """
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Edge
  alias Mnemosyne.Graph.Node, as: NodeProtocol
  alias Mnemosyne.Graph.Node.Subgoal
  alias Mnemosyne.Graph.Node.Tag

  defstruct nodes: %{}, by_type: %{}, by_tag: %{}, by_subgoal: %{}

  @type t :: %__MODULE__{
          nodes: %{String.t() => struct()},
          by_type: %{atom() => MapSet.t()},
          by_tag: %{String.t() => MapSet.t()},
          by_subgoal: %{String.t() => MapSet.t()}
        }

  @doc "Creates an empty graph."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Inserts a node into the graph, updating all secondary indexes."
  @spec put_node(t(), struct()) :: t()
  def put_node(%__MODULE__{} = graph, node) do
    id = NodeProtocol.id(node)
    type = NodeProtocol.node_type(node)

    graph
    |> put_in_nodes(id, node)
    |> index_by_type(type, id)
    |> maybe_index_tag(node, id)
    |> maybe_index_subgoal(node, id)
  end

  @doc "Fetches a node by its ID, returning `nil` if not found."
  @spec get_node(t(), String.t()) :: struct() | nil
  def get_node(%__MODULE__{nodes: nodes}, id), do: Map.get(nodes, id)

  @doc "Returns all nodes matching the given type atom."
  @spec nodes_by_type(t(), atom()) :: [struct()]
  def nodes_by_type(%__MODULE__{by_type: by_type, nodes: nodes}, type) do
    case Map.get(by_type, type) do
      nil -> []
      ids -> Enum.map(ids, &Map.fetch!(nodes, &1))
    end
  end

  @doc "Creates a typed bidirectional link between two nodes. No-op if either ID is missing."
  @spec link(t(), String.t(), String.t(), Edge.edge_type()) :: t()
  def link(%__MODULE__{nodes: nodes} = graph, id_a, id_b, type) do
    with {:ok, node_a} <- Map.fetch(nodes, id_a),
         {:ok, node_b} <- Map.fetch(nodes, id_b) do
      links_a = Map.update(node_a.links, type, MapSet.new([id_b]), &MapSet.put(&1, id_b))
      links_b = Map.update(node_b.links, type, MapSet.new([id_a]), &MapSet.put(&1, id_a))

      updated_a = %{node_a | links: links_a}
      updated_b = %{node_b | links: links_b}

      %{graph | nodes: nodes |> Map.put(id_a, updated_a) |> Map.put(id_b, updated_b)}
    else
      :error -> graph
    end
  end

  @doc "Removes a node from the graph, cleans up link references, and rebuilds indexes."
  @spec delete_node(t(), String.t()) :: t()
  def delete_node(%__MODULE__{} = graph, id) do
    case Map.pop(graph.nodes, id) do
      {nil, _} ->
        graph

      {_node, remaining} ->
        cleaned = Map.new(remaining, fn {nid, node} -> {nid, remove_link_ref(node, id)} end)
        rebuild_indexes(%{graph | nodes: cleaned})
    end
  end

  @doc "Applies a changeset's additions and links to the graph."
  @spec apply_changeset(t(), Changeset.t()) :: t()
  def apply_changeset(%__MODULE__{} = graph, %Changeset{} = cs) do
    Mnemosyne.Telemetry.span([:graph, :apply_changeset], %{}, fn ->
      result =
        graph
        |> apply_additions(cs.additions)
        |> apply_links(cs.links)

      {result, %{nodes_added: length(cs.additions), links_added: length(cs.links)}}
    end)
  end

  defp put_in_nodes(%__MODULE__{} = graph, id, node) do
    %{graph | nodes: Map.put(graph.nodes, id, node)}
  end

  defp index_by_type(%__MODULE__{by_type: by_type} = graph, type, id) do
    updated = Map.update(by_type, type, MapSet.new([id]), &MapSet.put(&1, id))
    %{graph | by_type: updated}
  end

  defp maybe_index_tag(graph, %Tag{label: label}, id) do
    key = label |> String.trim() |> String.downcase()
    updated = Map.update(graph.by_tag, key, MapSet.new([id]), &MapSet.put(&1, id))
    %{graph | by_tag: updated}
  end

  defp maybe_index_tag(graph, _node, _id), do: graph

  defp maybe_index_subgoal(graph, %Subgoal{description: desc}, id) do
    updated = Map.update(graph.by_subgoal, desc, MapSet.new([id]), &MapSet.put(&1, id))
    %{graph | by_subgoal: updated}
  end

  defp maybe_index_subgoal(graph, _node, _id), do: graph

  defp remove_link_ref(node, id) do
    updated_links = Map.new(node.links, fn {type, ids} -> {type, MapSet.delete(ids, id)} end)
    %{node | links: updated_links}
  end

  defp apply_additions(graph, additions) do
    Enum.reduce(additions, graph, &put_node(&2, &1))
  end

  defp apply_links(graph, links) do
    Enum.reduce(links, graph, fn {id_a, id_b, type}, g -> link(g, id_a, id_b, type) end)
  end

  defp rebuild_indexes(%__MODULE__{nodes: nodes} = graph) do
    Enum.reduce(nodes, %{graph | by_type: %{}, by_tag: %{}, by_subgoal: %{}}, fn {_id, node}, g ->
      id = NodeProtocol.id(node)
      type = NodeProtocol.node_type(node)

      g
      |> index_by_type(type, id)
      |> maybe_index_tag(node, id)
      |> maybe_index_subgoal(node, id)
    end)
  end
end
