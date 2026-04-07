defmodule Mnemosyne.Graph.Node.Semantic do
  @moduledoc """
  Semantic memory node representing a proposition with a confidence score.
  """
  use TypedStruct

  alias Mnemosyne.Graph.Edge

  typedstruct enforce: true do
    field :id, String.t()
    field :proposition, String.t()
    field :confidence, float()
    field :embedding, [float()] | nil, enforce: false, default: nil
    field :links, %{Edge.edge_type() => MapSet.t()}, enforce: false, default: Edge.empty_links()
    field :created_at, DateTime.t(), enforce: false, default: DateTime.utc_now()
  end

  defimpl Mnemosyne.Graph.Node do
    def id(node), do: node.id
    def embedding(node), do: node.embedding
    def links(node), do: node.links
    def links(node, type), do: Map.get(node.links, type, MapSet.new())
    def node_type(_node), do: :semantic
  end
end
