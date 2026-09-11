defmodule Mnemosyne.AccessControl.View do
  @moduledoc """
  Builds an isolated, read-only graph snapshot before retrieval or merging.

  Unauthorized nodes and their link references are removed before candidate
  scoring. The snapshot never carries persistence handles or ingestion receipts.
  This deliberately scans the repo for each view; large backends can eventually
  implement equivalent authorization-aware queries without changing the policy.
  """

  alias Mnemosyne.Graph
  alias Mnemosyne.Graph.Node
  alias Mnemosyne.GraphBackends.InMemory

  @node_types [:episodic, :semantic, :procedural, :subgoal, :source, :tag, :intent]

  @doc "Builds a view containing only nodes with the exact audience."
  @spec scope({module(), term()}, term()) :: {:ok, {module(), term()}} | {:error, term()}
  def scope(backend, audience) do
    build(backend, fn _node, metadata ->
      {:ok, Map.get(metadata || %{}, :audience) == audience}
    end)
  end

  @doc "Loads all supported node types and their metadata from a backend."
  @spec load({module(), term()}) :: {:ok, [struct()], map()} | {:error, term()}
  def load({module, state}) do
    with {:ok, nodes, _state} <- module.get_nodes_by_type(@node_types, state),
         ids = Enum.map(nodes, &Node.id/1),
         {:ok, metadata, _state} <- module.get_metadata(ids, state) do
      {:ok, nodes, metadata}
    end
  end

  @doc "Builds a snapshot using a decision function; evaluation errors abort the view."
  @spec build({module(), term()}, (struct(), struct() | nil ->
                                     {:ok, boolean()} | {:error, term()})) ::
          {:ok, {module(), term()}} | {:error, term()}
  def build(backend, decision) do
    with {:ok, nodes, metadata} <- load(backend),
         {:ok, visible} <- select(nodes, metadata, decision) do
      ids = MapSet.new(visible, &Node.id/1)

      graph = Enum.reduce(visible, Graph.new(), &Graph.put_node(&2, prune_links(&1, ids)))

      {:ok,
       {InMemory, %InMemory{graph: graph, metadata: Map.take(metadata, MapSet.to_list(ids))}}}
    end
  end

  defp prune_links(node, visible_ids) do
    links =
      Map.new(Node.links(node), fn {type, linked} ->
        {type, MapSet.intersection(linked, visible_ids)}
      end)

    %{node | links: links}
  end

  defp select(nodes, metadata, decision) do
    Enum.reduce_while(nodes, {:ok, []}, fn node, {:ok, visible} ->
      case decision.(node, Map.get(metadata, Node.id(node))) do
        {:ok, true} -> {:cont, {:ok, [node | visible]}}
        {:ok, false} -> {:cont, {:ok, visible}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
