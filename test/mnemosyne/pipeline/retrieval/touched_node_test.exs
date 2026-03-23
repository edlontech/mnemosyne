defmodule Mnemosyne.Pipeline.Retrieval.TouchedNodeTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Pipeline.Retrieval.TaggedCandidate
  alias Mnemosyne.Pipeline.Retrieval.TouchedNode

  @node %Semantic{id: "s1", proposition: "test", confidence: 0.9}

  test "from_tagged with :summary excludes node struct" do
    tc = TaggedCandidate.from_hop_0(@node, 0.85)
    tn = TouchedNode.from_tagged(tc, :summary)

    assert %TouchedNode{
             id: "s1",
             type: :semantic,
             score: 0.85,
             phase: :initial,
             hop: 0,
             node: nil
           } = tn
  end

  test "from_tagged with :detailed includes node struct" do
    tc = TaggedCandidate.from_hop_0(@node, 0.85)
    tn = TouchedNode.from_tagged(tc, :detailed)

    assert %TouchedNode{id: "s1", type: :semantic, score: 0.85, node: %Semantic{id: "s1"}} = tn
  end

  test "from_tagged propagates hop from multi_hop phase" do
    tc = TaggedCandidate.from_multi_hop(@node, 0.7, 3)
    tn = TouchedNode.from_tagged(tc, :summary)

    assert %TouchedNode{
             id: "s1",
             type: :semantic,
             score: 0.7,
             phase: :multi_hop,
             hop: 3,
             node: nil
           } = tn
  end

  test "from_tagged propagates nil hop from provenance phase" do
    tc = TaggedCandidate.from_provenance(@node, 0.4)
    tn = TouchedNode.from_tagged(tc, :summary)

    assert %TouchedNode{
             id: "s1",
             type: :semantic,
             score: 0.4,
             phase: :provenance,
             hop: nil,
             node: nil
           } = tn
  end
end
