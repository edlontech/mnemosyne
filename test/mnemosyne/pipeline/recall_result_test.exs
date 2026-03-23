defmodule Mnemosyne.Pipeline.RecallResultTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Notifier.Trace.Recall, as: RecallTrace
  alias Mnemosyne.Pipeline.Reasoning.ReasonedMemory
  alias Mnemosyne.Pipeline.RecallResult
  alias Mnemosyne.Pipeline.Retrieval.TouchedNode

  test "assembles with all fields" do
    result = %RecallResult{
      reasoned: %ReasonedMemory{semantic: "fact"},
      touched_nodes: [
        %TouchedNode{id: "s1", type: :semantic, score: 0.9, phase: :initial, hop: 0},
        %TouchedNode{id: "s2", type: :semantic, score: 0.7, phase: :multi_hop, hop: 1}
      ],
      trace: %RecallTrace{mode: :semantic, tags: ["test"]}
    }

    assert result.reasoned.semantic == "fact"
    assert length(result.touched_nodes) == 2
    assert result.trace.mode == :semantic
  end

  test "defaults to empty touched_nodes" do
    result = %RecallResult{
      reasoned: %ReasonedMemory{},
      trace: %RecallTrace{}
    }

    assert result.touched_nodes == []
  end
end
