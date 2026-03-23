defmodule Mnemosyne.Pipeline.Retrieval.TouchedNode do
  @moduledoc """
  Caller-facing projection of a retrieved candidate node.
  """

  use TypedStruct

  alias Mnemosyne.Graph.Node, as: NodeProtocol
  alias Mnemosyne.Pipeline.Retrieval.TaggedCandidate

  typedstruct do
    field :id, String.t(), enforce: true
    field :type, atom(), enforce: true
    field :score, float(), enforce: true
    field :phase, atom(), enforce: true
    field :hop, non_neg_integer() | nil
    field :node, struct() | nil
  end

  @spec from_tagged(TaggedCandidate.t(), :summary | :detailed) :: t()
  def from_tagged(%TaggedCandidate{} = tc, :summary) do
    %__MODULE__{
      id: NodeProtocol.id(tc.node),
      type: NodeProtocol.node_type(tc.node),
      score: tc.score,
      phase: tc.phase,
      hop: tc.hop,
      node: nil
    }
  end

  def from_tagged(%TaggedCandidate{} = tc, :detailed) do
    %__MODULE__{
      id: NodeProtocol.id(tc.node),
      type: NodeProtocol.node_type(tc.node),
      score: tc.score,
      phase: tc.phase,
      hop: tc.hop,
      node: tc.node
    }
  end
end
