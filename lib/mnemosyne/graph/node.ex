defprotocol Mnemosyne.Graph.Node do
  @moduledoc """
  Protocol for polymorphic graph node operations.

  All knowledge graph node types must implement this protocol
  to support uniform access to identity, embeddings, links, and type.
  """

  alias Mnemosyne.Graph.Edge

  @doc "Returns the unique identifier of the node."
  @spec id(t()) :: String.t()
  def id(node)

  @doc "Returns the embedding vector, or nil if not set."
  @spec embedding(t()) :: [float()] | nil
  def embedding(node)

  @doc "Returns all links grouped by edge type."
  @spec links(t()) :: %{Edge.edge_type() => MapSet.t()}
  def links(node)

  @doc "Returns the set of linked node IDs for a specific edge type."
  @spec links(t(), Edge.edge_type()) :: MapSet.t()
  def links(node, edge_type)

  @doc "Returns the atom identifying the node's type."
  @spec node_type(t()) :: atom()
  def node_type(node)
end

defmodule Mnemosyne.Graph.Node.Helpers do
  @moduledoc """
  Utility functions for working with node links across edge types.
  """

  alias Mnemosyne.Graph.Node, as: NodeProtocol

  @spec all_linked_ids(NodeProtocol.t()) :: MapSet.t()
  def all_linked_ids(node) do
    node |> NodeProtocol.links() |> Map.values() |> Enum.reduce(MapSet.new(), &MapSet.union/2)
  end
end
