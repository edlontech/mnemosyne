defprotocol Mnemosyne.Graph.Node do
  @moduledoc """
  Protocol for polymorphic graph node operations.

  All knowledge graph node types must implement this protocol
  to support uniform access to identity, embeddings, links, and type.
  """

  @spec id(t()) :: String.t()
  def id(node)

  @spec embedding(t()) :: [float()] | nil
  def embedding(node)

  @spec links(t()) :: MapSet.t()
  def links(node)

  @spec node_type(t()) :: atom()
  def node_type(node)
end
