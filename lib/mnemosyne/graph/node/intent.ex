defmodule Mnemosyne.Graph.Node.Intent do
  @moduledoc """
  Intent node representing a high-level goal that links to
  procedural prescription nodes for hierarchical retrieval.
  """
  alias Mnemosyne.Graph.Edge

  @enforce_keys [:id, :description]
  defstruct [
    :id,
    :description,
    embedding: nil,
    links: Edge.empty_links(),
    created_at: DateTime.utc_now()
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          description: String.t(),
          embedding: [float()] | nil,
          links: %{Edge.edge_type() => MapSet.t()},
          created_at: DateTime.t()
        }

  defimpl Mnemosyne.Graph.Node do
    def id(node), do: node.id
    def embedding(node), do: node.embedding
    def links(node), do: node.links
    def links(node, type), do: Map.get(node.links, type, MapSet.new())
    def node_type(_node), do: :intent
  end
end
