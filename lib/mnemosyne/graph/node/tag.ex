defmodule Mnemosyne.Graph.Node.Tag do
  @moduledoc """
  Tag node used to label and categorize other nodes in the graph.
  """
  alias Mnemosyne.Graph.Edge

  @enforce_keys [:id, :label]
  defstruct [
    :id,
    :label,
    embedding: nil,
    links: Edge.empty_links(),
    created_at: DateTime.utc_now()
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          label: String.t(),
          embedding: [float()] | nil,
          links: %{Edge.edge_type() => MapSet.t()},
          created_at: DateTime.t()
        }

  defimpl Mnemosyne.Graph.Node do
    def id(node), do: node.id
    def embedding(node), do: node.embedding
    def links(node), do: node.links
    def links(node, type), do: Map.get(node.links, type, MapSet.new())
    def node_type(_node), do: :tag
  end
end
