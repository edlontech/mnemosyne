defmodule Mnemosyne.Graph.Node.Subgoal do
  @moduledoc """
  Subgoal node representing a decomposed objective, optionally
  linked to a parent goal.
  """
  use TypedStruct

  typedstruct enforce: true do
    field :id, String.t()
    field :description, String.t()
    field :parent_goal, String.t() | nil, enforce: false, default: nil
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
    def node_type(_node), do: :subgoal
  end
end
