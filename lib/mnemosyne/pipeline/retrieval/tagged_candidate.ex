defmodule Mnemosyne.Pipeline.Retrieval.TaggedCandidate do
  @moduledoc """
  Internal struct representing a scored candidate with its origin phase.
  Replaces raw `{node, score}` tuples in the retrieval pipeline.
  """

  use TypedStruct

  typedstruct do
    field :node, struct(), enforce: true
    field :score, float(), enforce: true
    field :phase, atom(), enforce: true
    field :hop, non_neg_integer() | nil
  end

  @spec from_hop_0(struct(), float()) :: t()
  def from_hop_0(node, score) do
    %__MODULE__{node: node, score: score, phase: :initial, hop: 0}
  end

  @spec from_multi_hop(struct(), float(), non_neg_integer()) :: t()
  def from_multi_hop(node, score, hop) do
    %__MODULE__{node: node, score: score, phase: :multi_hop, hop: hop}
  end

  @spec from_refinement(struct(), float()) :: t()
  def from_refinement(node, score) do
    %__MODULE__{node: node, score: score, phase: :refinement, hop: nil}
  end

  @spec from_provenance(struct(), float()) :: t()
  def from_provenance(node, score) do
    %__MODULE__{node: node, score: score, phase: :provenance, hop: nil}
  end
end
