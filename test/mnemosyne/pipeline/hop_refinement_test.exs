defmodule Mnemosyne.Pipeline.HopRefinementTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Mnemosyne.Embedding
  alias Mnemosyne.Graph.Node.Episodic
  alias Mnemosyne.Graph.Node.Procedural
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.LLM
  alias Mnemosyne.MockEmbedding
  alias Mnemosyne.MockLLM
  alias Mnemosyne.Pipeline.HopRefinement
  alias Mnemosyne.Pipeline.HopRefinement.State
  alias Mnemosyne.Pipeline.Retrieval.TaggedCandidate

  setup :set_mimic_from_context

  @config %Mnemosyne.Config{
    llm: %{model: "test-model", opts: %{}},
    embedding: %{model: "test-embed", opts: %{}}
  }

  defp ctx do
    %{
      llm: MockLLM,
      embedding: MockEmbedding,
      config: @config,
      llm_opts: []
    }
  end

  defp semantic_candidate(id, score, hop) do
    node = %Semantic{
      id: id,
      proposition: "Proposition for #{id}",
      confidence: 0.9,
      embedding: List.duplicate(0.1, 8)
    }

    %TaggedCandidate{node: node, score: score, phase: :initial, hop: hop}
  end

  defp procedural_candidate(id, score, hop) do
    node = %Procedural{
      id: id,
      instruction: "Do something for #{id}",
      condition: "When needed",
      expected_outcome: "Success"
    }

    %TaggedCandidate{node: node, score: score, phase: :initial, hop: hop}
  end

  defp episodic_candidate(id, score, hop) do
    node = %Episodic{
      id: id,
      observation: "Saw something",
      action: "Did something",
      state: "state",
      subgoal: "goal",
      reward: 1.0,
      trajectory_id: "traj-1"
    }

    %TaggedCandidate{node: node, score: score, phase: :initial, hop: hop}
  end

  describe "init/2" do
    test "seeds previous_best_score with refinement_threshold from config" do
      state = HopRefinement.init(@config, 5)

      assert %State{} = state
      assert state.previous_best_score == 0.6
      assert state.plateau_delta == 0.05
    end

    test "caps budget at max_hops when refinement_budget exceeds it" do
      config = %{@config | refinement_budget: 10}
      state = HopRefinement.init(config, 3)

      assert state.budget_remaining == 3
    end

    test "uses refinement_budget when less than max_hops" do
      state = HopRefinement.init(@config, 5)

      assert state.budget_remaining == 1
    end

    test "starts with zero refinement_count and empty refinements" do
      state = HopRefinement.init(@config, 5)

      assert state.refinement_count == 0
      assert state.refinements == []
    end
  end

  describe "maybe_refine/5 - budget exhaustion" do
    test "returns :skip when budget_remaining is 0" do
      state = %State{
        budget_remaining: 0,
        previous_best_score: 0.5,
        plateau_delta: 0.05,
        refinement_count: 1,
        refinements: []
      }

      candidates = [semantic_candidate("s1", 0.7, 1)]

      assert {:skip, ^state} = HopRefinement.maybe_refine(state, "query", candidates, 1, ctx())
    end
  end

  describe "maybe_refine/5 - plateau detection triggers refinement" do
    test "triggers refinement when score delta is below plateau_delta" do
      state = %State{
        budget_remaining: 1,
        previous_best_score: 0.5,
        plateau_delta: 0.05,
        refinement_count: 0,
        refinements: []
      }

      candidates = [semantic_candidate("s1", 0.52, 1)]

      expect(MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        {:ok,
         %LLM.Response{
           content: %{tags: ["refined-tag-1", "refined-tag-2"]},
           model: "test",
           usage: %{}
         }}
      end)

      expect(MockEmbedding, :embed_batch, fn tags, _opts ->
        vectors = Enum.map(tags, fn _ -> List.duplicate(0.2, 8) end)
        {:ok, %Embedding.Response{vectors: vectors, model: "test", usage: %{}}}
      end)

      assert {:refined, tags, vectors, new_state} =
               HopRefinement.maybe_refine(state, "query", candidates, 1, ctx())

      assert tags == ["refined-tag-1", "refined-tag-2"]
      assert length(vectors) == 2
      assert new_state.budget_remaining == 0
      assert new_state.refinement_count == 1
      assert new_state.previous_best_score == 0.52
      assert length(new_state.refinements) == 1
    end

    test "skips refinement when score improvement exceeds plateau_delta" do
      state = %State{
        budget_remaining: 1,
        previous_best_score: 0.5,
        plateau_delta: 0.05,
        refinement_count: 0,
        refinements: []
      }

      candidates = [semantic_candidate("s1", 0.8, 1)]

      assert {:skip, new_state} =
               HopRefinement.maybe_refine(state, "query", candidates, 1, ctx())

      assert new_state.previous_best_score == 0.8
      assert new_state.budget_remaining == 1
    end
  end

  describe "maybe_refine/5 - hop 0 behavior" do
    test "triggers refinement when hop 0 score is below refinement_threshold seed" do
      state = HopRefinement.init(@config, 3)
      candidates = [semantic_candidate("s1", 0.55, 0)]

      expect(MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        {:ok,
         %LLM.Response{
           content: %{tags: ["new-tag"]},
           model: "test",
           usage: %{}
         }}
      end)

      expect(MockEmbedding, :embed_batch, fn _tags, _opts ->
        {:ok, %Embedding.Response{vectors: [List.duplicate(0.3, 8)], model: "test", usage: %{}}}
      end)

      assert {:refined, _tags, _vectors, new_state} =
               HopRefinement.maybe_refine(state, "query", candidates, 0, ctx())

      assert new_state.previous_best_score == 0.55
    end

    test "skips when hop 0 score exceeds refinement_threshold seed" do
      state = HopRefinement.init(@config, 3)
      candidates = [semantic_candidate("s1", 0.9, 0)]

      assert {:skip, new_state} =
               HopRefinement.maybe_refine(state, "query", candidates, 0, ctx())

      assert new_state.previous_best_score == 0.9
    end
  end

  describe "maybe_refine/5 - LLM failure" do
    test "returns :skip without consuming budget on LLM error" do
      state = %State{
        budget_remaining: 1,
        previous_best_score: 0.5,
        plateau_delta: 0.05,
        refinement_count: 0,
        refinements: []
      }

      candidates = [semantic_candidate("s1", 0.52, 1)]

      expect(MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        {:error, %Mnemosyne.Errors.Framework.AdapterError{adapter: MockLLM}}
      end)

      assert {:skip, new_state} =
               HopRefinement.maybe_refine(state, "query", candidates, 1, ctx())

      assert new_state.budget_remaining == 1
      assert new_state.refinement_count == 0
      assert new_state.previous_best_score == 0.52
    end

    test "returns :skip without consuming budget when parse returns empty tags" do
      state = %State{
        budget_remaining: 1,
        previous_best_score: 0.5,
        plateau_delta: 0.05,
        refinement_count: 0,
        refinements: []
      }

      candidates = [semantic_candidate("s1", 0.52, 1)]

      expect(MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        {:ok,
         %LLM.Response{
           content: %{tags: []},
           model: "test",
           usage: %{}
         }}
      end)

      assert {:skip, new_state} =
               HopRefinement.maybe_refine(state, "query", candidates, 1, ctx())

      assert new_state.budget_remaining == 1
      assert new_state.previous_best_score == 0.52
    end
  end

  describe "maybe_refine/5 - refined return includes tags and vectors" do
    test "returns matching tags and vectors from LLM and embedding calls" do
      state = %State{
        budget_remaining: 1,
        previous_best_score: 0.5,
        plateau_delta: 0.05,
        refinement_count: 0,
        refinements: []
      }

      candidates = [semantic_candidate("s1", 0.52, 1)]
      expected_tags = ["alpha", "beta", "gamma"]
      expected_vectors = Enum.map(1..3, fn i -> List.duplicate(i * 0.1, 8) end)

      expect(MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        {:ok,
         %LLM.Response{
           content: %{tags: expected_tags},
           model: "test",
           usage: %{}
         }}
      end)

      expect(MockEmbedding, :embed_batch, fn ^expected_tags, _opts ->
        {:ok, %Embedding.Response{vectors: expected_vectors, model: "test", usage: %{}}}
      end)

      assert {:refined, ^expected_tags, ^expected_vectors, _state} =
               HopRefinement.maybe_refine(state, "query", candidates, 1, ctx())
    end
  end

  describe "maybe_refine/5 - candidate filtering by hop" do
    test "only considers candidates from the current hop for best score" do
      state = %State{
        budget_remaining: 1,
        previous_best_score: 0.5,
        plateau_delta: 0.05,
        refinement_count: 0,
        refinements: []
      }

      candidates = [
        semantic_candidate("old", 0.9, 0),
        semantic_candidate("new", 0.52, 1)
      ]

      expect(MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        {:ok,
         %LLM.Response{
           content: %{tags: ["tag"]},
           model: "test",
           usage: %{}
         }}
      end)

      expect(MockEmbedding, :embed_batch, fn _tags, _opts ->
        {:ok, %Embedding.Response{vectors: [List.duplicate(0.1, 8)], model: "test", usage: %{}}}
      end)

      assert {:refined, _tags, _vectors, new_state} =
               HopRefinement.maybe_refine(state, "query", candidates, 1, ctx())

      assert new_state.previous_best_score == 0.52
    end
  end

  describe "maybe_refine/5 - mode inference in prompt" do
    test "passes inferred mode to the prompt based on candidate types" do
      state = %State{
        budget_remaining: 1,
        previous_best_score: 0.5,
        plateau_delta: 0.05,
        refinement_count: 0,
        refinements: []
      }

      candidates = [
        semantic_candidate("s1", 0.52, 1),
        procedural_candidate("p1", 0.48, 1)
      ]

      expect(MockLLM, :chat_structured, fn messages, _schema, _opts ->
        [%{content: system_msg} | _] = messages
        assert system_msg =~ "mixed"

        {:ok,
         %LLM.Response{
           content: %{tags: ["tag"]},
           model: "test",
           usage: %{}
         }}
      end)

      expect(MockEmbedding, :embed_batch, fn _tags, _opts ->
        {:ok, %Embedding.Response{vectors: [List.duplicate(0.1, 8)], model: "test", usage: %{}}}
      end)

      assert {:refined, _tags, _vectors, _state} =
               HopRefinement.maybe_refine(state, "query", candidates, 1, ctx())
    end
  end

  describe "maybe_refine/5 - summarize_with_hops formatting" do
    test "includes hop labels in candidate summaries" do
      state = %State{
        budget_remaining: 1,
        previous_best_score: 0.5,
        plateau_delta: 0.05,
        refinement_count: 0,
        refinements: []
      }

      candidates = [
        semantic_candidate("s0", 0.4, 0),
        semantic_candidate("s1", 0.52, 1)
      ]

      expect(MockLLM, :chat_structured, fn messages, _schema, _opts ->
        [_, %{content: user_msg}] = messages
        assert user_msg =~ "[Hop 0]"
        assert user_msg =~ "[Hop 1 - new]"

        {:ok,
         %LLM.Response{
           content: %{tags: ["tag"]},
           model: "test",
           usage: %{}
         }}
      end)

      expect(MockEmbedding, :embed_batch, fn _tags, _opts ->
        {:ok, %Embedding.Response{vectors: [List.duplicate(0.1, 8)], model: "test", usage: %{}}}
      end)

      assert {:refined, _tags, _vectors, _state} =
               HopRefinement.maybe_refine(state, "query", candidates, 1, ctx())
    end

    test "uses episodic content format for episodic nodes" do
      state = %State{
        budget_remaining: 1,
        previous_best_score: 0.5,
        plateau_delta: 0.05,
        refinement_count: 0,
        refinements: []
      }

      candidates = [episodic_candidate("e1", 0.52, 1)]

      expect(MockLLM, :chat_structured, fn messages, _schema, _opts ->
        [_, %{content: user_msg}] = messages
        assert user_msg =~ "Saw something -> Did something"

        {:ok,
         %LLM.Response{
           content: %{tags: ["tag"]},
           model: "test",
           usage: %{}
         }}
      end)

      expect(MockEmbedding, :embed_batch, fn _tags, _opts ->
        {:ok, %Embedding.Response{vectors: [List.duplicate(0.1, 8)], model: "test", usage: %{}}}
      end)

      assert {:refined, _tags, _vectors, _state} =
               HopRefinement.maybe_refine(state, "query", candidates, 1, ctx())
    end
  end

  describe "maybe_refine/5 - sequential multi-hop with budget > 1" do
    test "fires refinement at two consecutive hops and threads state correctly" do
      state = %State{
        budget_remaining: 2,
        previous_best_score: 0.6,
        plateau_delta: 0.05,
        refinement_count: 0,
        refinements: []
      }

      hop1_candidates = [semantic_candidate("s1", 0.62, 1)]

      expect(MockLLM, :chat_structured, 2, fn _messages, _schema, _opts ->
        {:ok,
         %LLM.Response{
           content: %{tags: ["bridge-tag"]},
           model: "test",
           usage: %{}
         }}
      end)

      expect(MockEmbedding, :embed_batch, 2, fn _tags, _opts ->
        {:ok, %Embedding.Response{vectors: [List.duplicate(0.2, 8)], model: "test", usage: %{}}}
      end)

      assert {:refined, _, _, state_after_hop1} =
               HopRefinement.maybe_refine(state, "query", hop1_candidates, 1, ctx())

      assert state_after_hop1.budget_remaining == 1
      assert state_after_hop1.refinement_count == 1
      assert state_after_hop1.previous_best_score == 0.62
      assert length(state_after_hop1.refinements) == 1

      hop2_candidates =
        hop1_candidates ++ [semantic_candidate("s2", 0.63, 2)]

      assert {:refined, _, _, state_after_hop2} =
               HopRefinement.maybe_refine(state_after_hop1, "query", hop2_candidates, 2, ctx())

      assert state_after_hop2.budget_remaining == 0
      assert state_after_hop2.refinement_count == 2
      assert state_after_hop2.previous_best_score == 0.63
      assert length(state_after_hop2.refinements) == 2

      [first_ref, second_ref] = Enum.reverse(state_after_hop2.refinements)
      assert first_ref.hop == 1
      assert second_ref.hop == 2
    end

    test "fires at hop 1 then skips hop 2 when improvement is sufficient" do
      state = %State{
        budget_remaining: 2,
        previous_best_score: 0.6,
        plateau_delta: 0.05,
        refinement_count: 0,
        refinements: []
      }

      hop1_candidates = [semantic_candidate("s1", 0.62, 1)]

      expect(MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        {:ok,
         %LLM.Response{
           content: %{tags: ["bridge-tag"]},
           model: "test",
           usage: %{}
         }}
      end)

      expect(MockEmbedding, :embed_batch, fn _tags, _opts ->
        {:ok, %Embedding.Response{vectors: [List.duplicate(0.2, 8)], model: "test", usage: %{}}}
      end)

      assert {:refined, _, _, state_after_hop1} =
               HopRefinement.maybe_refine(state, "query", hop1_candidates, 1, ctx())

      hop2_candidates =
        hop1_candidates ++ [semantic_candidate("s2", 0.85, 2)]

      assert {:skip, state_after_hop2} =
               HopRefinement.maybe_refine(state_after_hop1, "query", hop2_candidates, 2, ctx())

      assert state_after_hop2.budget_remaining == 1
      assert state_after_hop2.refinement_count == 1
      assert state_after_hop2.previous_best_score == 0.85
    end

    test "falls back to previous_best_score when no candidates match current hop" do
      state = %State{
        budget_remaining: 2,
        previous_best_score: 0.7,
        plateau_delta: 0.05,
        refinement_count: 0,
        refinements: []
      }

      candidates_all_from_hop0 = [semantic_candidate("s1", 0.8, 0)]

      assert {:skip, new_state} =
               HopRefinement.maybe_refine(state, "query", candidates_all_from_hop0, 1, ctx())

      assert new_state.previous_best_score == 0.7
      assert new_state.budget_remaining == 2
    end
  end
end
