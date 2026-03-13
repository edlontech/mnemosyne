defmodule Mnemosyne.Graph.Node.Intent do
  @moduledoc """
  Intent node representing a high-level goal that links to
  procedural prescription nodes for hierarchical retrieval.
  """
  use TypedStruct

  typedstruct enforce: true do
    field :id, String.t()
    field :description, String.t()
    field :embedding, [float()] | nil, enforce: false, default: nil
    field :links, MapSet.t(), enforce: false, default: MapSet.new()
    field :created_at, DateTime.t(), enforce: false, default: DateTime.utc_now()
  end

  defimpl Mnemosyne.Graph.Node do
    def id(node), do: node.id
    def embedding(node), do: node.embedding
    def links(node), do: node.links
    def node_type(_node), do: :intent
  end
end
