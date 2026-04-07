defmodule Mnemosyne.Graph.Node.Procedural do
  @moduledoc """
  Procedural memory node encoding an instruction with its
  triggering condition and expected outcome.
  """
  use TypedStruct

  alias Mnemosyne.Graph.Edge

  typedstruct enforce: true do
    field :id, String.t()
    field :instruction, String.t()
    field :condition, String.t()
    field :expected_outcome, String.t()
    field :return_score, float() | nil, enforce: false, default: nil
    field :embedding, [float()] | nil, enforce: false, default: nil
    field :links, %{Edge.edge_type() => MapSet.t()}, enforce: false, default: Edge.empty_links()
    field :created_at, DateTime.t(), enforce: false, default: DateTime.utc_now()
  end

  defimpl Mnemosyne.Graph.Node do
    def id(node), do: node.id
    def embedding(node), do: node.embedding
    def links(node), do: node.links
    def links(node, type), do: Map.get(node.links, type, MapSet.new())
    def node_type(_node), do: :procedural
  end
end
