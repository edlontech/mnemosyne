defmodule Mnemosyne.Graph.Node.Procedural do
  @moduledoc """
  Procedural memory node encoding an instruction with its
  triggering condition and expected outcome.
  """
  use TypedStruct

  typedstruct enforce: true do
    field :id, String.t()
    field :instruction, String.t()
    field :condition, String.t()
    field :expected_outcome, String.t()
    field :embedding, [float()] | nil, enforce: false, default: nil
    field :links, MapSet.t(), enforce: false, default: MapSet.new()
    field :created_at, DateTime.t(), enforce: false, default: DateTime.utc_now()
  end

  defimpl Mnemosyne.Graph.Node do
    def id(node), do: node.id
    def embedding(node), do: node.embedding
    def links(node), do: node.links
    def node_type(_node), do: :procedural
  end
end
