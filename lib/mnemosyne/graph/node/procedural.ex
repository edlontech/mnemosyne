defmodule Mnemosyne.Graph.Node.Procedural do
  @moduledoc """
  Procedural memory node encoding an instruction with its
  triggering condition and expected outcome.
  """
  alias Mnemosyne.Graph.Edge

  @enforce_keys [:id, :instruction, :condition, :expected_outcome]
  defstruct [
    :id,
    :instruction,
    :condition,
    :expected_outcome,
    return_score: nil,
    embedding: nil,
    links: Edge.empty_links(),
    created_at: DateTime.utc_now()
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          instruction: String.t(),
          condition: String.t(),
          expected_outcome: String.t(),
          return_score: float() | nil,
          embedding: [float()] | nil,
          links: %{Edge.edge_type() => MapSet.t()},
          created_at: DateTime.t()
        }

  defimpl Mnemosyne.Graph.Node do
    def id(node), do: node.id
    def embedding(node), do: node.embedding
    def links(node), do: node.links
    def links(node, type), do: Map.get(node.links, type, MapSet.new())
    def node_type(_node), do: :procedural
  end
end
