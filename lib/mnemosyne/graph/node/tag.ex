defmodule Mnemosyne.Graph.Node.Tag do
  @moduledoc """
  Tag node used to label and categorize other nodes in the graph.
  """
  use TypedStruct

  typedstruct enforce: true do
    field :id, String.t()
    field :label, String.t()
    field :embedding, [float()] | nil, enforce: false, default: nil
    field :links, MapSet.t(), enforce: false, default: MapSet.new()
    field :created_at, DateTime.t(), enforce: false, default: DateTime.utc_now()
  end

  defimpl Mnemosyne.Graph.Node do
    @doc false
    def id(node), do: node.id
    @doc false
    def embedding(node), do: node.embedding
    @doc false
    def links(node), do: node.links
    @doc false
    def node_type(_node), do: :tag
  end
end
