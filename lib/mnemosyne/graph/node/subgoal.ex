defmodule Mnemosyne.Graph.Node.Subgoal do
  @moduledoc """
  Subgoal node representing a decomposed objective, optionally
  linked to a parent goal.
  """
  alias Mnemosyne.Graph.Edge

  @enforce_keys [:id, :description]
  defstruct [
    :id,
    :description,
    parent_goal: nil,
    embedding: nil,
    links: Edge.empty_links(),
    created_at: DateTime.utc_now()
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          description: String.t(),
          parent_goal: String.t() | nil,
          embedding: [float()] | nil,
          links: %{Edge.edge_type() => MapSet.t()},
          created_at: DateTime.t()
        }

  defimpl Mnemosyne.Graph.Node do
    def id(node), do: node.id
    def embedding(node), do: node.embedding
    def links(node), do: node.links
    def links(node, type), do: Map.get(node.links, type, MapSet.new())
    def node_type(_node), do: :subgoal
  end
end
