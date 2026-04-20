defmodule Mnemosyne.Graph.Node.Semantic do
  @moduledoc """
  Semantic memory node representing a proposition with a confidence score.
  """
  alias Mnemosyne.Graph.Edge

  @enforce_keys [:id, :proposition, :confidence]
  defstruct [
    :id,
    :proposition,
    :confidence,
    embedding: nil,
    links: Edge.empty_links(),
    created_at: DateTime.utc_now()
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          proposition: String.t(),
          confidence: float(),
          embedding: [float()] | nil,
          links: %{Edge.edge_type() => MapSet.t()},
          created_at: DateTime.t()
        }

  defimpl Mnemosyne.Graph.Node do
    def id(node), do: node.id
    def embedding(node), do: node.embedding
    def links(node), do: node.links
    def links(node, type), do: Map.get(node.links, type, MapSet.new())
    def node_type(_node), do: :semantic
  end
end
