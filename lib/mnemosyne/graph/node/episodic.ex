defmodule Mnemosyne.Graph.Node.Episodic do
  @moduledoc """
  Episodic memory node capturing an observation-action-reward tuple
  within a trajectory.
  """
  alias Mnemosyne.Graph.Edge

  @enforce_keys [:id, :observation, :action, :state, :subgoal, :reward, :trajectory_id]
  defstruct [
    :id,
    :observation,
    :action,
    :state,
    :subgoal,
    :reward,
    :trajectory_id,
    embedding: nil,
    links: Edge.empty_links(),
    created_at: DateTime.utc_now()
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          observation: String.t(),
          action: String.t(),
          state: String.t(),
          subgoal: String.t(),
          reward: float(),
          trajectory_id: String.t(),
          embedding: [float()] | nil,
          links: %{Edge.edge_type() => MapSet.t()},
          created_at: DateTime.t()
        }

  defimpl Mnemosyne.Graph.Node do
    def id(node), do: node.id
    def embedding(node), do: node.embedding
    def links(node), do: node.links
    def links(node, type), do: Map.get(node.links, type, MapSet.new())
    def node_type(_node), do: :episodic
  end
end
