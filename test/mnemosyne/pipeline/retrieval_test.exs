defmodule Mnemosyne.Pipeline.RetrievalTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.Graph
  alias Mnemosyne.Graph.Node.Episodic
  alias Mnemosyne.Graph.Node.Intent
  alias Mnemosyne.Graph.Node.Procedural
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Source
  alias Mnemosyne.Graph.Node.Subgoal
  alias Mnemosyne.Graph.Node.Tag
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.LLM
  alias Mnemosyne.Pipeline.Retrieval

  @default_opts [
    llm: Mnemosyne.MockLLM,
    embedding: Mnemosyne.MockEmbedding
  ]

  @test_vector List.duplicate(0.1, 128)
  @alt_vector List.duplicate(0.2, 128)

  @value_function %{
    module: Mnemosyne.ValueFunction.Default,
    params: %{
      episodic: %{threshold: 0.0, top_k: 30, lambda: 0.01, k: 5, base_floor: 0.3, beta: 1.0},
      semantic: %{threshold: 0.0, top_k: 20, lambda: 0.01, k: 5, base_floor: 0.3, beta: 1.0},
      procedural: %{threshold: 0.0, top_k: 10, lambda: 0.01, k: 5, base_floor: 0.3, beta: 1.0},
      subgoal: %{threshold: 0.0, top_k: 10, lambda: 0.01, k: 5, base_floor: 0.3, beta: 1.0},
      tag: %{threshold: 0.0, top_k: 10, lambda: 0.01, k: 5, base_floor: 0.3, beta: 1.0},
      source: %{threshold: 0.0, top_k: 50, lambda: 0.01, k: 5, base_floor: 0.3, beta: 1.0},
      intent: %{threshold: 0.0, top_k: 10, lambda: 0.01, k: 5, base_floor: 0.3, beta: 1.0}
    }
  }

  setup :set_mimic_from_context

  defp build_test_graph do
    Graph.new()
    |> Graph.put_node(%Semantic{
      id: "sem_1",
      proposition: "Elixir runs on BEAM",
      confidence: 0.95,
      embedding: @test_vector
    })
    |> Graph.put_node(%Semantic{
      id: "sem_2",
      proposition: "OTP provides fault tolerance",
      confidence: 0.88,
      embedding: @alt_vector
    })
    |> Graph.put_node(%Procedural{
      id: "proc_1",
      instruction: "Run migrations first",
      condition: "deploying to prod",
      expected_outcome: "schema updated",
      embedding: @test_vector
    })
    |> Graph.put_node(%Episodic{
      id: "ep_1",
      observation: "Server crashed",
      action: "Restarted service",
      state: "Degraded",
      reward: 0.3,
      trajectory_id: "traj_1",
      embedding: @test_vector
    })
    |> Graph.put_node(%Episodic{
      id: "ep_2",
      observation: "Service recovered",
      action: "Verified health",
      state: "Healthy",
      reward: 0.9,
      trajectory_id: "traj_1",
      embedding: @alt_vector
    })
    |> Graph.put_node(%Subgoal{
      id: "sg_1",
      description: "Restore service health",
      parent_goal: "Maintain uptime"
    })
    |> Graph.put_node(%Source{
      id: "src_1",
      episode_id: "episode_001",
      step_index: 0
    })
    |> Graph.put_node(%Tag{
      id: "tag_1",
      label: "deployment",
      embedding: @test_vector
    })
    |> Graph.put_node(%Intent{
      id: "int_1",
      description: "Deploy application safely",
      embedding: @test_vector,
      links: MapSet.new(["proc_1"])
    })
    |> Graph.link("tag_1", "sem_1")
    |> Graph.link("ep_1", "sg_1")
    |> Graph.link("ep_1", "src_1")
    |> Graph.link("ep_2", "sg_1")
  end

  defp stub_retrieval_llm(mode \\ "semantic", tags \\ "BEAM VM\nfault tolerance") do
    Mnemosyne.MockLLM
    |> stub(:chat, fn messages, _opts ->
      system_content =
        messages
        |> Enum.find(%{content: ""}, &(&1.role == :system))
        |> Map.get(:content)

      content =
        cond do
          system_content =~ "classifying memory retrieval" -> mode
          system_content =~ "planning memory retrieval" -> tags
          true -> "default"
        end

      {:ok, %LLM.Response{content: content, model: "mock:test", usage: %{}}}
    end)
  end

  defp stub_default_embedding do
    Mnemosyne.MockEmbedding
    |> stub(:embed, fn _text, _opts ->
      {:ok, %Embedding.Response{vectors: [@test_vector], model: "mock:embed", usage: %{}}}
    end)
    |> stub(:embed_batch, fn texts, _opts ->
      vectors = Enum.map(texts, fn _ -> @test_vector end)
      {:ok, %Embedding.Response{vectors: vectors, model: "mock:embed", usage: %{}}}
    end)
  end

  defp retrieval_opts(graph, extra \\ []) do
    backend_state = %InMemory{graph: graph}

    @default_opts ++
      [backend: {InMemory, backend_state}, value_function: @value_function] ++ extra
  end

  describe "retrieve/2" do
    test "returns retrieval result with mode, tags, and candidates" do
      graph = build_test_graph()
      stub_retrieval_llm()
      stub_default_embedding()

      assert {:ok, %Retrieval.Result{} = result} =
               Retrieval.retrieve("Tell me about Elixir", retrieval_opts(graph))

      assert result.mode == :semantic
      assert ["BEAM VM", "fault tolerance"] = result.tags
      assert is_map(result.candidates)
    end

    test "semantic mode retrieves semantic and tag nodes" do
      graph = build_test_graph()
      stub_retrieval_llm("semantic")
      stub_default_embedding()

      {:ok, result} = Retrieval.retrieve("What is BEAM?", retrieval_opts(graph))

      assert result.mode == :semantic
      candidate_types = Map.keys(result.candidates)
      assert :semantic in candidate_types
    end

    test "episodic mode retrieves episodic nodes and expands provenance" do
      graph = build_test_graph()
      stub_retrieval_llm("episodic", "server crash\nservice recovery")
      stub_default_embedding()

      {:ok, result} =
        Retrieval.retrieve("What happened during the outage?", retrieval_opts(graph))

      assert result.mode == :episodic
      candidate_types = Map.keys(result.candidates)
      assert :episodic in candidate_types
    end

    test "procedural mode retrieves procedural nodes" do
      graph = build_test_graph()
      stub_retrieval_llm("procedural", "deployment\nmigrations")
      stub_default_embedding()

      {:ok, result} = Retrieval.retrieve("How do I deploy?", retrieval_opts(graph))

      assert result.mode == :procedural
      candidate_types = Map.keys(result.candidates)
      assert :procedural in candidate_types
    end

    test "mixed mode retrieves all node types" do
      graph = build_test_graph()
      stub_retrieval_llm("mixed", "Elixir\ndeployment")
      stub_default_embedding()

      {:ok, result} = Retrieval.retrieve("Tell me everything", retrieval_opts(graph))

      assert result.mode == :mixed
    end

    test "max_hops 0 returns only hop-0 results without traversal" do
      graph = build_test_graph()
      stub_retrieval_llm("semantic")
      stub_default_embedding()

      {:ok, result} =
        Retrieval.retrieve("Elixir facts", retrieval_opts(graph, max_hops: 0))

      all_ids =
        result.candidates
        |> Map.values()
        |> List.flatten()
        |> Enum.map(fn {node, _score} -> node.id end)

      refute "ep_1" in all_ids
      refute "ep_2" in all_ids
      refute "proc_1" in all_ids
    end

    test "multi-hop traversal discovers linked nodes" do
      graph = build_test_graph()
      stub_retrieval_llm("episodic", "server crash")
      stub_default_embedding()

      {:ok, result} =
        Retrieval.retrieve("What happened?", retrieval_opts(graph, max_hops: 2))

      all_candidates =
        result.candidates
        |> Map.values()
        |> List.flatten()
        |> Enum.map(fn {node, _score} -> node.id end)

      assert "ep_1" in all_candidates or "ep_2" in all_candidates
    end

    test "handles empty graph gracefully" do
      graph = Graph.new()
      stub_retrieval_llm()
      stub_default_embedding()

      {:ok, result} = Retrieval.retrieve("anything", retrieval_opts(graph))

      total_candidates =
        result.candidates
        |> Map.values()
        |> List.flatten()
        |> length()

      assert total_candidates == 0
    end

    test "propagates LLM errors" do
      graph = build_test_graph()
      stub_default_embedding()

      Mnemosyne.MockLLM
      |> stub(:chat, fn _messages, _opts -> {:error, :llm_unavailable} end)

      assert {:error, :llm_unavailable} =
               Retrieval.retrieve("test", retrieval_opts(graph))
    end

    test "propagates embedding errors" do
      graph = build_test_graph()
      stub_retrieval_llm()

      Mnemosyne.MockEmbedding
      |> stub(:embed, fn _text, _opts -> {:error, :embed_failed} end)
      |> stub(:embed_batch, fn _texts, _opts -> {:error, :embed_failed} end)

      assert {:error, :embed_failed} =
               Retrieval.retrieve("test", retrieval_opts(graph))
    end

    test "accepts config option for per-step model resolution" do
      graph = build_test_graph()
      stub_default_embedding()

      config = %Config{
        llm: %{model: "test:model", opts: %{}},
        embedding: %{model: "test:embed", opts: %{}},
        value_function: %{module: Mnemosyne.ValueFunction.Default, params: %{}},
        overrides: %{get_mode: %{model: "test:fast", opts: %{}}}
      }

      Mnemosyne.MockLLM
      |> stub(:chat, fn messages, opts ->
        system_content =
          messages
          |> Enum.find(%{content: ""}, &(&1.role == :system))
          |> Map.get(:content)

        if system_content =~ "classifying memory retrieval" do
          assert Keyword.get(opts, :model) == "test:fast"
        end

        content =
          cond do
            system_content =~ "classifying memory retrieval" -> "semantic"
            system_content =~ "planning memory retrieval" -> "BEAM VM"
            true -> "default"
          end

        {:ok, %LLM.Response{content: content, model: "mock:test", usage: %{}}}
      end)

      opts = retrieval_opts(graph, config: config)
      assert {:ok, %Retrieval.Result{}} = Retrieval.retrieve("test", opts)
    end

    test "procedural mode discovers prescriptions through intent nodes" do
      graph = build_test_graph()
      stub_retrieval_llm("procedural", "deploy safely")
      stub_default_embedding()

      {:ok, result} =
        Retrieval.retrieve("How do I deploy safely?", retrieval_opts(graph, max_hops: 2))

      all_ids =
        result.candidates
        |> Map.values()
        |> List.flatten()
        |> Enum.map(fn {node, _score} -> node.id end)

      assert "int_1" in all_ids or "proc_1" in all_ids
    end

    test "semantic mode discovers propositions through concept tags" do
      graph = build_test_graph()
      stub_retrieval_llm("semantic", "deployment")
      stub_default_embedding()

      {:ok, result} =
        Retrieval.retrieve("What about deployment?", retrieval_opts(graph, max_hops: 2))

      all_ids =
        result.candidates
        |> Map.values()
        |> List.flatten()
        |> Enum.map(fn {node, _score} -> node.id end)

      assert "tag_1" in all_ids or "sem_1" in all_ids
    end

    test "candidates include scores as floats" do
      graph = build_test_graph()
      stub_retrieval_llm()
      stub_default_embedding()

      {:ok, result} = Retrieval.retrieve("Elixir BEAM", retrieval_opts(graph))

      result.candidates
      |> Map.values()
      |> List.flatten()
      |> Enum.each(fn {_node, score} ->
        assert is_float(score)
      end)
    end
  end
end
