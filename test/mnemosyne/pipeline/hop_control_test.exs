defmodule Mnemosyne.Pipeline.HopControlTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Mnemosyne.Embedding
  alias Mnemosyne.Graph.Node.Episodic
  alias Mnemosyne.Graph.Node.Procedural
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.LLM
  alias Mnemosyne.MockEmbedding
  alias Mnemosyne.MockLLM
  alias Mnemosyne.Pipeline.HopControl
  alias Mnemosyne.Pipeline.HopControl.State
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

  defp control_response(enough, indices) do
    {:ok,
     %LLM.Response{
       content: %{enough: enough, top_indices: indices},
       model: "test",
       usage: %{}
     }}
  end

  describe "init/2" do
    test "caps budget at max_hops when refinement_budget exceeds it" do
      config = %{@config | refinement_budget: 10}
      state = HopControl.init(config, 3)

      assert state.budget_remaining == 3
    end

    test "uses refinement_budget when less than max_hops" do
      config = %{@config | refinement_budget: 1}
      state = HopControl.init(config, 5)

      assert state.budget_remaining == 1
    end

    test "starts with zero refinement_count, empty refinements, no early stop" do
      state = HopControl.init(@config, 5)

      assert state.refinement_count == 0
      assert state.refinements == []
      assert state.stopped_early_at == nil
    end

    test "disables refinement without config but keeps controller active" do
      state = HopControl.init(nil, 5)

      assert %State{budget_remaining: 0} = state
    end
  end

  describe "assess/5 - sufficiency decision" do
    test "returns :stop and records the hop when the controller says enough" do
      candidates = [semantic_candidate("s1", 0.9, 0)]

      expect(MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        control_response(true, [])
      end)

      assert {:stop, state} = HopControl.assess(%State{}, "query", candidates, 1, ctx())
      assert state.stopped_early_at == 1
    end

    test "returns :continue with focus candidates selected by index" do
      candidates = [
        semantic_candidate("s1", 0.9, 0),
        semantic_candidate("s2", 0.8, 0),
        semantic_candidate("s3", 0.7, 0)
      ]

      expect(MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        control_response(false, [2, 0])
      end)

      assert {:continue, focus, _state} =
               HopControl.assess(%State{}, "query", candidates, 1, ctx())

      assert Enum.map(focus, & &1.node.id) == ["s3", "s1"]
    end

    test "caps focus set at two candidates and drops invalid indices" do
      candidates = [
        semantic_candidate("s1", 0.9, 0),
        semantic_candidate("s2", 0.8, 0),
        semantic_candidate("s3", 0.7, 0)
      ]

      expect(MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        control_response(false, [99, -1, 1, 0, 2])
      end)

      assert {:continue, focus, _state} =
               HopControl.assess(%State{}, "query", candidates, 1, ctx())

      assert Enum.map(focus, & &1.node.id) == ["s2", "s1"]
    end

    test "continues without an LLM call when there are no candidates" do
      assert {:continue, [], %State{}} = HopControl.assess(%State{}, "query", [], 1, ctx())
    end

    test "degrades to :continue with no focus on LLM error" do
      candidates = [semantic_candidate("s1", 0.9, 0)]

      expect(MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        {:error, %Mnemosyne.Errors.Framework.AdapterError{adapter: MockLLM}}
      end)

      assert {:continue, [], _state} = HopControl.assess(%State{}, "query", candidates, 1, ctx())
    end

    test "degrades to :continue on unparseable controller output" do
      candidates = [semantic_candidate("s1", 0.9, 0)]

      expect(MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        {:ok, %LLM.Response{content: %{summary: "unrelated"}, model: "test", usage: %{}}}
      end)

      assert {:continue, [], _state} = HopControl.assess(%State{}, "query", candidates, 1, ctx())
    end

    test "presents indexed candidates to the controller" do
      candidates = [
        semantic_candidate("s1", 0.9, 0),
        episodic_candidate("e1", 0.8, 0)
      ]

      expect(MockLLM, :chat_structured, fn messages, _schema, _opts ->
        [_, %{content: user_msg}] = messages
        assert user_msg =~ "[0] (semantic) Proposition for s1"
        assert user_msg =~ "[1] (episodic) Saw something -> Did something"

        control_response(false, [])
      end)

      assert {:continue, [], _state} = HopControl.assess(%State{}, "query", candidates, 1, ctx())
    end
  end

  describe "refine/5 - budget exhaustion" do
    test "returns :skip when budget_remaining is 0" do
      state = %State{budget_remaining: 0, refinement_count: 1}
      candidates = [semantic_candidate("s1", 0.7, 1)]

      assert {:skip, ^state} = HopControl.refine(state, "query", candidates, 1, ctx())
    end
  end

  describe "refine/5 - tag regeneration" do
    test "regenerates tags conditioned on retrieved candidates" do
      state = %State{budget_remaining: 1}
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
               HopControl.refine(state, "query", candidates, 1, ctx())

      assert tags == ["refined-tag-1", "refined-tag-2"]
      assert length(vectors) == 2
      assert new_state.budget_remaining == 0
      assert new_state.refinement_count == 1
      assert length(new_state.refinements) == 1
    end

    test "returns matching tags and vectors from LLM and embedding calls" do
      state = %State{budget_remaining: 1}
      candidates = [semantic_candidate("s1", 0.52, 1)]
      expected_tags = ["alpha", "beta", "gamma"]
      expected_vectors = Enum.map(1..3, fn i -> List.duplicate(i * 0.1, 8) end)

      expect(MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        {:ok, %LLM.Response{content: %{tags: expected_tags}, model: "test", usage: %{}}}
      end)

      expect(MockEmbedding, :embed_batch, fn ^expected_tags, _opts ->
        {:ok, %Embedding.Response{vectors: expected_vectors, model: "test", usage: %{}}}
      end)

      assert {:refined, ^expected_tags, ^expected_vectors, _state} =
               HopControl.refine(state, "query", candidates, 1, ctx())
    end
  end

  describe "refine/5 - LLM failure" do
    test "returns :skip without consuming budget on LLM error" do
      state = %State{budget_remaining: 1}
      candidates = [semantic_candidate("s1", 0.52, 1)]

      expect(MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        {:error, %Mnemosyne.Errors.Framework.AdapterError{adapter: MockLLM}}
      end)

      assert {:skip, new_state} = HopControl.refine(state, "query", candidates, 1, ctx())

      assert new_state.budget_remaining == 1
      assert new_state.refinement_count == 0
    end

    test "returns :skip without consuming budget when parse returns empty tags" do
      state = %State{budget_remaining: 1}
      candidates = [semantic_candidate("s1", 0.52, 1)]

      expect(MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        {:ok, %LLM.Response{content: %{tags: []}, model: "test", usage: %{}}}
      end)

      assert {:skip, new_state} = HopControl.refine(state, "query", candidates, 1, ctx())

      assert new_state.budget_remaining == 1
    end
  end

  describe "refine/5 - mode inference in prompt" do
    test "passes inferred mode to the prompt based on candidate types" do
      state = %State{budget_remaining: 1}

      candidates = [
        semantic_candidate("s1", 0.52, 1),
        procedural_candidate("p1", 0.48, 1)
      ]

      expect(MockLLM, :chat_structured, fn messages, _schema, _opts ->
        [%{content: system_msg} | _] = messages
        assert system_msg =~ "mixed"

        {:ok, %LLM.Response{content: %{tags: ["tag"]}, model: "test", usage: %{}}}
      end)

      expect(MockEmbedding, :embed_batch, fn _tags, _opts ->
        {:ok, %Embedding.Response{vectors: [List.duplicate(0.1, 8)], model: "test", usage: %{}}}
      end)

      assert {:refined, _tags, _vectors, _state} =
               HopControl.refine(state, "query", candidates, 1, ctx())
    end
  end

  describe "refine/5 - summarize_with_hops formatting" do
    test "includes hop labels in candidate summaries" do
      state = %State{budget_remaining: 1}

      candidates = [
        semantic_candidate("s0", 0.4, 0),
        semantic_candidate("s1", 0.52, 1)
      ]

      expect(MockLLM, :chat_structured, fn messages, _schema, _opts ->
        [_, %{content: user_msg}] = messages
        assert user_msg =~ "[Hop 0]"
        assert user_msg =~ "[Hop 1 - new]"

        {:ok, %LLM.Response{content: %{tags: ["tag"]}, model: "test", usage: %{}}}
      end)

      expect(MockEmbedding, :embed_batch, fn _tags, _opts ->
        {:ok, %Embedding.Response{vectors: [List.duplicate(0.1, 8)], model: "test", usage: %{}}}
      end)

      assert {:refined, _tags, _vectors, _state} =
               HopControl.refine(state, "query", candidates, 1, ctx())
    end

    test "uses episodic content format for episodic nodes" do
      state = %State{budget_remaining: 1}
      candidates = [episodic_candidate("e1", 0.52, 1)]

      expect(MockLLM, :chat_structured, fn messages, _schema, _opts ->
        [_, %{content: user_msg}] = messages
        assert user_msg =~ "Saw something -> Did something"

        {:ok, %LLM.Response{content: %{tags: ["tag"]}, model: "test", usage: %{}}}
      end)

      expect(MockEmbedding, :embed_batch, fn _tags, _opts ->
        {:ok, %Embedding.Response{vectors: [List.duplicate(0.1, 8)], model: "test", usage: %{}}}
      end)

      assert {:refined, _tags, _vectors, _state} =
               HopControl.refine(state, "query", candidates, 1, ctx())
    end
  end

  describe "refine/5 - sequential multi-hop with budget > 1" do
    test "fires refinement at two consecutive hops and threads state correctly" do
      state = %State{budget_remaining: 2}
      hop1_candidates = [semantic_candidate("s1", 0.62, 1)]

      expect(MockLLM, :chat_structured, 2, fn _messages, _schema, _opts ->
        {:ok, %LLM.Response{content: %{tags: ["bridge-tag"]}, model: "test", usage: %{}}}
      end)

      expect(MockEmbedding, :embed_batch, 2, fn _tags, _opts ->
        {:ok, %Embedding.Response{vectors: [List.duplicate(0.2, 8)], model: "test", usage: %{}}}
      end)

      assert {:refined, _, _, state_after_hop1} =
               HopControl.refine(state, "query", hop1_candidates, 1, ctx())

      assert state_after_hop1.budget_remaining == 1
      assert state_after_hop1.refinement_count == 1
      assert length(state_after_hop1.refinements) == 1

      hop2_candidates = hop1_candidates ++ [semantic_candidate("s2", 0.63, 2)]

      assert {:refined, _, _, state_after_hop2} =
               HopControl.refine(state_after_hop1, "query", hop2_candidates, 2, ctx())

      assert state_after_hop2.budget_remaining == 0
      assert state_after_hop2.refinement_count == 2
      assert length(state_after_hop2.refinements) == 2

      [first_ref, second_ref] = Enum.reverse(state_after_hop2.refinements)
      assert first_ref.hop == 1
      assert second_ref.hop == 2
    end
  end
end
