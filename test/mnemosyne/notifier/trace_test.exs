defmodule Mnemosyne.Notifier.TraceTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Notifier.Trace.Episode
  alias Mnemosyne.Notifier.Trace.Recall
  alias Mnemosyne.Notifier.Trace.Structuring

  describe "Recall trace" do
    test "defaults to summary verbosity" do
      trace = %Recall{}
      assert trace.verbosity == :summary
    end

    test "summary-level fields have correct defaults" do
      trace = %Recall{}
      assert trace.tags == []
      assert trace.candidate_count == 0
      assert trace.hops == 0
      assert trace.result_count == 0
      assert trace.duration_us == 0
      assert trace.mode == nil
    end

    test "detailed-only fields default to nil" do
      trace = %Recall{}
      assert trace.candidates_per_hop == nil
      assert trace.scores == nil
      assert trace.rejected == nil
      assert trace.phase_timings == nil
    end

    test "detailed verbosity can populate all fields" do
      trace = %Recall{
        verbosity: :detailed,
        mode: :semantic,
        tags: ["elixir", "genserver"],
        candidate_count: 5,
        hops: 2,
        result_count: 3,
        duration_us: 1500,
        candidates_per_hop: [%{hop: 0, count: 3}, %{hop: 1, count: 2}],
        scores: [%{node_id: "n1", score: 0.9}],
        rejected: [%{node_id: "n2", reason: :below_threshold}],
        phase_timings: %{classify: 100, embed: 200, search: 1200}
      }

      assert trace.verbosity == :detailed
      assert trace.mode == :semantic
      assert length(trace.tags) == 2
      assert length(trace.candidates_per_hop) == 2
      assert length(trace.scores) == 1
      assert length(trace.rejected) == 1
      assert trace.phase_timings.classify == 100
    end
  end

  describe "Episode trace" do
    test "defaults to summary verbosity" do
      trace = %Episode{}
      assert trace.verbosity == :summary
    end

    test "summary-level fields have correct defaults" do
      trace = %Episode{}
      assert trace.step_index == 0
      assert trace.trajectory_id == nil
      assert trace.boundary_detected == false
      assert trace.reward == 0.0
      assert trace.duration_us == 0
    end

    test "detailed-only fields default to nil" do
      trace = %Episode{}
      assert trace.subgoal == nil
      assert trace.similarity_score == nil
      assert trace.similarity_threshold == nil
      assert trace.state_summary == nil
    end

    test "detailed verbosity can populate all fields" do
      trace = %Episode{
        verbosity: :detailed,
        step_index: 3,
        trajectory_id: "traj-abc",
        boundary_detected: true,
        reward: 0.85,
        duration_us: 2000,
        subgoal: "find relevant docs",
        similarity_score: 0.72,
        similarity_threshold: 0.75,
        state_summary: "agent searched documentation"
      }

      assert trace.verbosity == :detailed
      assert trace.step_index == 3
      assert trace.trajectory_id == "traj-abc"
      assert trace.boundary_detected == true
      assert trace.similarity_score == 0.72
      assert trace.state_summary == "agent searched documentation"
    end
  end

  describe "Structuring trace" do
    test "defaults to summary verbosity" do
      trace = %Structuring{}
      assert trace.verbosity == :summary
    end

    test "summary-level fields have correct defaults" do
      trace = %Structuring{}
      assert trace.trajectory_id == nil
      assert trace.semantic_count == 0
      assert trace.procedural_count == 0
      assert trace.tag_count == 0
      assert trace.intent_count == 0
      assert trace.duration_us == 0
    end

    test "detailed-only fields default to nil" do
      trace = %Structuring{}
      assert trace.semantic_nodes == nil
      assert trace.procedural_nodes == nil
      assert trace.merged_intents == nil
      assert trace.phase_timings == nil
    end

    test "detailed verbosity can populate all fields" do
      trace = %Structuring{
        verbosity: :detailed,
        trajectory_id: "traj-xyz",
        semantic_count: 3,
        procedural_count: 2,
        tag_count: 5,
        intent_count: 1,
        duration_us: 5000,
        semantic_nodes: [%{id: "s1"}, %{id: "s2"}, %{id: "s3"}],
        procedural_nodes: [%{id: "p1"}, %{id: "p2"}],
        merged_intents: [%{id: "i1", merged_from: ["i2"]}],
        phase_timings: %{semantic: 1500, procedural: 1200, tags: 800, intents: 1500}
      }

      assert trace.verbosity == :detailed
      assert trace.trajectory_id == "traj-xyz"
      assert trace.semantic_count == 3
      assert length(trace.semantic_nodes) == 3
      assert length(trace.merged_intents) == 1
      assert trace.phase_timings.semantic == 1500
    end
  end
end
