defmodule Mnemosyne.Pipeline.Retrieval.TouchedNode do
  @moduledoc """
  Caller-facing projection of a retrieved candidate node.
  """

  alias Mnemosyne.Graph.Node, as: NodeProtocol
  alias Mnemosyne.Pipeline.Retrieval.TaggedCandidate

  @enforce_keys [:id, :type, :score, :phase]
  defstruct [:id, :type, :score, :phase, :hop, :node]

  @type t :: %__MODULE__{
          id: String.t(),
          type: atom(),
          score: float(),
          phase: atom(),
          hop: non_neg_integer() | nil,
          node: struct() | nil
        }

  @doc "Projects a `TaggedCandidate` into a caller-facing `TouchedNode` at the given verbosity level."
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
