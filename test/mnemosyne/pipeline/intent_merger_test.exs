defmodule Mnemosyne.Pipeline.IntentMergerTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Intent
  alias Mnemosyne.Graph.Node.Procedural
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.LLM
  alias Mnemosyne.NodeMetadata
  alias Mnemosyne.Pipeline.IntentMerger

  setup :set_mimic_from_context

  @config %Config{
    llm: %{model: "test:model", opts: %{}},
    embedding: %{model: "test:embed", opts: %{}},
    overrides: %{},
    value_function: %{module: Mnemosyne.ValueFunction.Default, params: %{}},
    intent_merge_threshold: 0.8,
    intent_identity_threshold: 0.95
  }

  @backend_state %InMemory{}

  @base_opts [
    backend: {InMemory, @backend_state},
    llm: Mnemosyne.MockLLM,
    embedding: Mnemosyne.MockEmbedding,
    config: @config,
    value_function: %{module: Mnemosyne.ValueFunction.Default, params: %{}}
  ]

  defp make_intent(id, description, embedding) do
    %Intent{id: id, description: description, embedding: embedding}
  end

  defp make_procedural(id) do
    %Procedural{
      id: id,
      instruction: "do something",
      condition: "when needed",
      expected_outcome: "it works",
      embedding: [0.1, 0.2, 0.3]
    }
  end

  describe "merge/2 with no intents" do
    test "returns changeset unchanged when it contains only non-intent nodes" do
      sem = %Semantic{
        id: "sem_1",
        proposition: "test fact",
        confidence: 1.0,
        embedding: [0.1, 0.2, 0.3]
      }

      cs = Changeset.add_node(Changeset.new(), sem)

      assert {:ok, result} = IntentMerger.merge(cs, @base_opts)
      assert result.additions == cs.additions
      assert result.links == cs.links
    end
  end

  describe "merge/2 with no match (below threshold)" do
    test "keeps new intent when no similar intent exists in graph" do
      intent = make_intent("int_new", "Deploy to production", [1.0, 0.0, 0.0])
      proc = make_procedural("proc_1")

      cs =
        Changeset.new()
        |> Changeset.add_node(intent)
        |> Changeset.add_node(proc)
        |> Changeset.add_link("int_new", "proc_1")

      InMemory
      |> expect(:find_candidates, fn [:intent], _emb, [], _vf_config, [], @backend_state ->
        {:ok, [], @backend_state}
      end)

      assert {:ok, result} = IntentMerger.merge(cs, @base_opts)

      intent_nodes = Enum.filter(result.additions, &match?(%Intent{}, &1))
      assert [%Intent{id: "int_new", description: "Deploy to production"}] = intent_nodes
      assert {"int_new", "proc_1"} in result.links
    end
  end

  describe "merge/2 with identity match (>= 0.95)" do
    test "drops duplicate intent and rewrites links to existing" do
      new_intent = make_intent("int_new", "Optimize database", [0.99, 0.01, 0.0])

      existing_intent =
        make_intent("int_existing", "Optimize database queries", [0.99, 0.01, 0.0])

      proc = make_procedural("proc_1")

      cs =
        Changeset.new()
        |> Changeset.add_node(new_intent)
        |> Changeset.add_node(proc)
        |> Changeset.add_link("int_new", "proc_1")

      InMemory
      |> expect(:find_candidates, fn [:intent], _emb, [], _vf_config, [], @backend_state ->
        {:ok, [{existing_intent, 0.97}], @backend_state}
      end)

      assert {:ok, result} = IntentMerger.merge(cs, @base_opts)

      intent_nodes = Enum.filter(result.additions, &match?(%Intent{}, &1))
      assert intent_nodes == []

      assert {"int_existing", "proc_1"} in result.links
      refute {"int_new", "proc_1"} in result.links
    end
  end

  describe "merge/2 with LLM merge (0.8-0.95)" do
    test "merges intent via LLM, re-embeds, and rewrites links" do
      new_intent = make_intent("int_new", "Deploy app", [0.9, 0.1, 0.0])
      existing_intent = make_intent("int_existing", "Deploy service", [0.9, 0.1, 0.0])
      proc = make_procedural("proc_1")

      cs =
        Changeset.new()
        |> Changeset.add_node(new_intent)
        |> Changeset.add_node(proc)
        |> Changeset.add_link("int_new", "proc_1")

      InMemory
      |> expect(:find_candidates, fn [:intent], _emb, [], _vf_config, [], @backend_state ->
        {:ok, [{existing_intent, 0.88}], @backend_state}
      end)

      Mnemosyne.MockLLM
      |> expect(:chat_structured, fn _messages, _schema, _opts ->
        {:ok,
         %LLM.Response{
           content: %{merged_intent: "Deploy application service"},
           model: "test:model",
           usage: %{}
         }}
      end)

      Mnemosyne.MockEmbedding
      |> expect(:embed_batch, fn ["Deploy application service"], _opts ->
        {:ok,
         %Embedding.Response{
           vectors: [[0.95, 0.05, 0.0]],
           model: "test:embed",
           usage: %{}
         }}
      end)

      assert {:ok, result} = IntentMerger.merge(cs, @base_opts)

      intent_nodes = Enum.filter(result.additions, &match?(%Intent{}, &1))

      assert [%Intent{id: "int_existing", description: "Deploy application service"}] =
               intent_nodes

      assert [0.95, 0.05, 0.0] == hd(intent_nodes).embedding

      assert {"int_existing", "proc_1"} in result.links
      refute {"int_new", "proc_1"} in result.links
    end
  end

  describe "merge/2 with LLM failure" do
    test "falls back to keeping new intent when LLM merge fails" do
      new_intent = make_intent("int_new", "Deploy app", [0.9, 0.1, 0.0])
      existing_intent = make_intent("int_existing", "Deploy service", [0.9, 0.1, 0.0])
      proc = make_procedural("proc_1")

      cs =
        Changeset.new()
        |> Changeset.add_node(new_intent)
        |> Changeset.add_node(proc)
        |> Changeset.add_link("int_new", "proc_1")

      InMemory
      |> expect(:find_candidates, fn [:intent], _emb, [], _vf_config, [], @backend_state ->
        {:ok, [{existing_intent, 0.88}], @backend_state}
      end)

      Mnemosyne.MockLLM
      |> expect(:chat_structured, fn _messages, _schema, _opts ->
        {:error, :llm_unavailable}
      end)

      assert {:ok, result} = IntentMerger.merge(cs, @base_opts)

      intent_nodes = Enum.filter(result.additions, &match?(%Intent{}, &1))
      assert [%Intent{id: "int_new", description: "Deploy app"}] = intent_nodes
      assert {"int_new", "proc_1"} in result.links
    end
  end

  describe "merge/2 with intra-batch deduplication" do
    test "deduplicates similar intents within the same changeset" do
      intent_a = make_intent("int_a", "Deploy to production", [0.99, 0.01, 0.0])
      intent_b = make_intent("int_b", "Deploy to prod", [0.99, 0.01, 0.0])
      proc_a = make_procedural("proc_a")
      proc_b = make_procedural("proc_b")

      cs =
        Changeset.new()
        |> Changeset.add_node(intent_a)
        |> Changeset.add_node(intent_b)
        |> Changeset.add_node(proc_a)
        |> Changeset.add_node(proc_b)
        |> Changeset.add_link("int_a", "proc_a")
        |> Changeset.add_link("int_b", "proc_b")

      InMemory
      |> stub(:find_candidates, fn [:intent], _emb, [], _vf_config, [], @backend_state ->
        {:ok, [], @backend_state}
      end)

      assert {:ok, result} = IntentMerger.merge(cs, @base_opts)

      intent_nodes = Enum.filter(result.additions, &match?(%Intent{}, &1))
      assert length(intent_nodes) == 1

      [kept] = intent_nodes
      assert {kept.id, "proc_a"} in result.links
      assert {kept.id, "proc_b"} in result.links
    end
  end

  describe "metadata reward propagation" do
    test "identity match propagates reward from new intent to existing" do
      new_intent = make_intent("int_new", "Optimize database", [0.99, 0.01, 0.0])

      existing_intent =
        make_intent("int_existing", "Optimize database queries", [0.99, 0.01, 0.0])

      proc = make_procedural("proc_1")
      new_meta = NodeMetadata.new(cumulative_reward: 2.5, reward_count: 1)

      cs =
        Changeset.new()
        |> Changeset.add_node(new_intent)
        |> Changeset.add_node(proc)
        |> Changeset.add_link("int_new", "proc_1")
        |> Changeset.put_metadata("int_new", new_meta)

      InMemory
      |> expect(:find_candidates, fn [:intent], _emb, [], _vf_config, [], @backend_state ->
        {:ok, [{existing_intent, 0.97}], @backend_state}
      end)

      assert {:ok, result} = IntentMerger.merge(cs, @base_opts)

      refute Map.has_key?(result.metadata, "int_new")

      assert %NodeMetadata{cumulative_reward: 2.5, reward_count: 1} =
               result.metadata["int_existing"]
    end

    test "LLM merge propagates reward from new intent to merged intent" do
      new_intent = make_intent("int_new", "Deploy app", [0.9, 0.1, 0.0])
      existing_intent = make_intent("int_existing", "Deploy service", [0.9, 0.1, 0.0])
      proc = make_procedural("proc_1")
      new_meta = NodeMetadata.new(cumulative_reward: 3.0, reward_count: 1)

      cs =
        Changeset.new()
        |> Changeset.add_node(new_intent)
        |> Changeset.add_node(proc)
        |> Changeset.add_link("int_new", "proc_1")
        |> Changeset.put_metadata("int_new", new_meta)

      InMemory
      |> expect(:find_candidates, fn [:intent], _emb, [], _vf_config, [], @backend_state ->
        {:ok, [{existing_intent, 0.88}], @backend_state}
      end)

      Mnemosyne.MockLLM
      |> expect(:chat_structured, fn _messages, _schema, _opts ->
        {:ok,
         %LLM.Response{
           content: %{merged_intent: "Deploy application service"},
           model: "test:model",
           usage: %{}
         }}
      end)

      Mnemosyne.MockEmbedding
      |> expect(:embed_batch, fn ["Deploy application service"], _opts ->
        {:ok,
         %Embedding.Response{
           vectors: [[0.95, 0.05, 0.0]],
           model: "test:embed",
           usage: %{}
         }}
      end)

      assert {:ok, result} = IntentMerger.merge(cs, @base_opts)

      refute Map.has_key?(result.metadata, "int_new")

      assert %NodeMetadata{cumulative_reward: 3.0, reward_count: 1} =
               result.metadata["int_existing"]
    end

    test "identity match propagates even when cumulative_reward is zero" do
      new_intent = make_intent("int_new", "Optimize database", [0.99, 0.01, 0.0])

      existing_intent =
        make_intent("int_existing", "Optimize database queries", [0.99, 0.01, 0.0])

      proc = make_procedural("proc_1")
      new_meta = NodeMetadata.new(cumulative_reward: 0.0, reward_count: 1)

      cs =
        Changeset.new()
        |> Changeset.add_node(new_intent)
        |> Changeset.add_node(proc)
        |> Changeset.add_link("int_new", "proc_1")
        |> Changeset.put_metadata("int_new", new_meta)

      InMemory
      |> expect(:find_candidates, fn [:intent], _emb, [], _vf_config, [], @backend_state ->
        {:ok, [{existing_intent, 0.97}], @backend_state}
      end)

      assert {:ok, result} = IntentMerger.merge(cs, @base_opts)

      refute Map.has_key?(result.metadata, "int_new")

      existing_meta = result.metadata["int_existing"]
      assert existing_meta.cumulative_reward == 0.0
      assert existing_meta.reward_count == 1
    end

    test "no match preserves metadata unchanged" do
      intent = make_intent("int_new", "Deploy to production", [1.0, 0.0, 0.0])
      proc = make_procedural("proc_1")
      intent_meta = NodeMetadata.new(cumulative_reward: 1.0)

      cs =
        Changeset.new()
        |> Changeset.add_node(intent)
        |> Changeset.add_node(proc)
        |> Changeset.add_link("int_new", "proc_1")
        |> Changeset.put_metadata("int_new", intent_meta)

      InMemory
      |> expect(:find_candidates, fn [:intent], _emb, [], _vf_config, [], @backend_state ->
        {:ok, [], @backend_state}
      end)

      assert {:ok, result} = IntentMerger.merge(cs, @base_opts)

      assert %NodeMetadata{cumulative_reward: 1.0} = result.metadata["int_new"]
    end
  end
end
