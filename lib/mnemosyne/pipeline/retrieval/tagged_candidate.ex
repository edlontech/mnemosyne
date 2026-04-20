defmodule Mnemosyne.Pipeline.Retrieval.TaggedCandidate do
  @moduledoc """
  Internal struct representing a scored candidate with its origin phase.
  Replaces raw `{node, score}` tuples in the retrieval pipeline.
  """

  @enforce_keys [:node, :score, :phase]
  defstruct [:node, :score, :phase, :hop]

  @type t :: %__MODULE__{
          node: struct(),
          score: float(),
          phase: atom(),
          hop: non_neg_integer() | nil
        }

  @doc "Builds a tagged candidate from the initial retrieval phase (hop 0)."
  @spec from_hop_0(struct(), float()) :: t()
  def from_hop_0(node, score) do
    %__MODULE__{node: node, score: score, phase: :initial, hop: 0}
  end

  @doc "Builds a tagged candidate discovered during multi-hop traversal at the given hop depth."
  @spec from_multi_hop(struct(), float(), non_neg_integer()) :: t()
  def from_multi_hop(node, score, hop) do
    %__MODULE__{node: node, score: score, phase: :multi_hop, hop: hop}
  end

  @doc "Builds a tagged candidate from the query refinement phase at the given hop."
  @spec from_refinement(struct(), float(), non_neg_integer()) :: t()
  def from_refinement(node, score, hop) do
    %__MODULE__{node: node, score: score, phase: :refinement, hop: hop}
  end

  @doc "Builds a tagged candidate from the provenance lookup phase."
  @spec from_provenance(struct(), float()) :: t()
  def from_provenance(node, score) do
    %__MODULE__{node: node, score: score, phase: :provenance, hop: nil}
  end
end
