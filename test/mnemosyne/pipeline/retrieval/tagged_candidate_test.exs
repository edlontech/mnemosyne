defmodule Mnemosyne.Pipeline.Retrieval.TaggedCandidateTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Pipeline.Retrieval.TaggedCandidate

  @node %Semantic{id: "s1", proposition: "test", confidence: 0.9}

  test "from_hop_0 sets phase :initial and hop 0" do
    tc = TaggedCandidate.from_hop_0(@node, 0.85)
    assert %TaggedCandidate{phase: :initial, hop: 0, score: 0.85, node: @node} = tc
  end

  test "from_multi_hop sets phase :multi_hop with hop number" do
    tc = TaggedCandidate.from_multi_hop(@node, 0.7, 2)
    assert %TaggedCandidate{phase: :multi_hop, hop: 2, score: 0.7} = tc
  end

  test "from_refinement sets phase :refinement with hop" do
    tc = TaggedCandidate.from_refinement(@node, 0.6, 1)
    assert %TaggedCandidate{phase: :refinement, hop: 1, score: 0.6} = tc
  end

  test "from_provenance sets phase :provenance with nil hop" do
    tc = TaggedCandidate.from_provenance(@node, 0.4)
    assert %TaggedCandidate{phase: :provenance, hop: nil, score: 0.4} = tc
  end
end
