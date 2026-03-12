defprotocol Mnemosyne.Graph.Node do
  @moduledoc """
  Protocol for polymorphic graph node operations.

  All knowledge graph node types must implement this protocol
  to support uniform access to identity, embeddings, links, and type.
  """

  @doc "Returns the unique identifier of the node."
  @spec id(t()) :: String.t()
  def id(node)

  @doc "Returns the embedding vector, or nil if not set."
  @spec embedding(t()) :: [float()] | nil
  def embedding(node)

  @doc "Returns the set of linked node IDs."
  @spec links(t()) :: MapSet.t()
  def links(node)

  @doc "Returns the atom identifying the node's type."
  @spec node_type(t()) :: atom()
  def node_type(node)
end
