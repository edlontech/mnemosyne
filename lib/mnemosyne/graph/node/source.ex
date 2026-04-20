defmodule Mnemosyne.Graph.Node.Source do
  @moduledoc """
  Source node linking back to a specific step within an episode.
  """
  alias Mnemosyne.Graph.Edge

  @enforce_keys [:id, :episode_id, :step_index]
  defstruct [
    :id,
    :episode_id,
    :step_index,
    plain_text: nil,
    embedding: nil,
    links: Edge.empty_links(),
    created_at: DateTime.utc_now()
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          episode_id: String.t(),
          step_index: integer(),
          plain_text: String.t() | nil,
          embedding: [float()] | nil,
          links: %{Edge.edge_type() => MapSet.t()},
          created_at: DateTime.t()
        }

  defimpl Mnemosyne.Graph.Node do
    def id(node), do: node.id
    def embedding(node), do: node.embedding
    def links(node), do: node.links
    def links(node, type), do: Map.get(node.links, type, MapSet.new())
    def node_type(_node), do: :source
  end
end
