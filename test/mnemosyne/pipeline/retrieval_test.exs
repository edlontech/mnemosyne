defmodule Mnemosyne.Pipeline.RetrievalTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.Graph
  alias Mnemosyne.Graph.Node, as: NodeProtocol
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

  @far_vector List.duplicate(-0.3, 128)
  defp build_routing_test_graph do
    Graph.new()
    |> Graph.put_node(%Semantic{
      id: "sem_pasta",
      proposition: "Pasta is Italian",
      confidence: 0.9,
      embedding: @test_vector
    })
    |> Graph.put_node(%Semantic{
      id: "sem_risotto",
      proposition: "Risotto is Italian",
      confidence: 0.9,
      embedding: @alt_vector
    })
    |> Graph.put_node(%Semantic{
      id: "sem_sushi",
      proposition: "Sushi is Japanese",
      confidence: 0.9,
      embedding: @far_vector
    })
    |> Graph.put_node(%Tag{
      id: "tag_cooking",
      label: "cooking",
      embedding: @test_vector
    })
    |> Graph.put_node(%Tag{
      id: "tag_italian",
      label: "italian",
      embedding: @alt_vector
    })
    |> Graph.put_node(%Procedural{
      id: "proc_migrate",
      instruction: "Run migrations",
      condition: "deploying",
      expected_outcome: "schema updated",
      embedding: @test_vector
    })
    |> Graph.put_node(%Procedural{
      id: "proc_rollback",
      instruction: "Rollback migrations",
      condition: "deploy failed",
      expected_outcome: "schema reverted",
      embedding: @far_vector
    })
    |> Graph.put_node(%Intent{
      id: "intent_deploy",
      description: "Deploy application",
      embedding: @test_vector
    })
    |> Graph.put_node(%Source{
      id: "src_orphan",
      episode_id: "ep_001",
      step_index: 0
    })
    |> Graph.link("tag_cooking", "sem_pasta")
    |> Graph.link("tag_cooking", "sem_risotto")
    |> Graph.link("tag_cooking", "sem_sushi")
    |> Graph.link("tag_italian", "sem_pasta")
    |> Graph.link("tag_italian", "sem_risotto")
    |> Graph.link("intent_deploy", "proc_migrate")
    |> Graph.link("intent_deploy", "proc_rollback")
  end

  defp build_provenance_graph do
    Graph.new()
    |> Graph.put_node(%Episodic{
      id: "ep_1",
      observation: "Server crashed under load",
      action: "Added connection pooling",
      state: "Degraded",
      reward: 0.7,
      trajectory_id: "traj_1",
      embedding: @test_vector
    })
    |> Graph.put_node(%Episodic{
      id: "ep_2",
      observation: "Pool stabilized throughput",
      action: "Verified metrics",
      state: "Healthy",
      reward: 0.9,
      trajectory_id: "traj_1",
      embedding: @alt_vector
    })
    |> Graph.put_node(%Source{id: "src_1", episode_id: "episode_1", step_index: 0})
    |> Graph.put_node(%Source{id: "src_2", episode_id: "episode_1", step_index: 1})
    |> Graph.put_node(%Subgoal{
      id: "sg_1",
      description: "Fix server stability",
      parent_goal: "Improve uptime"
    })
    |> Graph.put_node(%Semantic{
      id: "sem_pool",
      proposition: "Connection pooling prevents resource exhaustion",
      confidence: 0.95,
      embedding: @test_vector
    })
    |> Graph.put_node(%Semantic{
      id: "sem_throughput",
      proposition: "Pooling improves throughput under high concurrency",
      confidence: 0.9,
      embedding: @alt_vector
    })
    |> Graph.put_node(%Tag{id: "tag_pooling", label: "pooling", embedding: @test_vector})
    |> Graph.put_node(%Tag{id: "tag_perf", label: "performance", embedding: @alt_vector})
    |> Graph.put_node(%Procedural{
      id: "proc_pool",
      instruction: "Configure connection pool size based on load",
      condition: "Database connections exceed threshold",
      expected_outcome: "Stable response times",
      embedding: @test_vector
    })
    |> Graph.put_node(%Intent{
      id: "int_scale",
      description: "Scale database connections",
      embedding: @test_vector
    })
    # episodic structure
    |> Graph.link("ep_1", "sg_1")
    |> Graph.link("ep_1", "src_1")
    |> Graph.link("ep_2", "sg_1")
    |> Graph.link("ep_2", "src_2")
    # semantic subgraph: tag → semantic (membership)
    |> Graph.link("tag_pooling", "sem_pool")
    |> Graph.link("tag_pooling", "sem_throughput")
    |> Graph.link("tag_perf", "sem_throughput")
    # semantic sibling
    |> Graph.link("sem_pool", "sem_throughput")
    # procedural subgraph: intent → procedural (hierarchical)
    |> Graph.link("int_scale", "proc_pool")
    # provenance: semantic → episodic
    |> Graph.link("sem_pool", "ep_1")
    |> Graph.link("sem_pool", "ep_2")
    |> Graph.link("sem_throughput", "ep_1")
    |> Graph.link("sem_throughput", "ep_2")
    # provenance: procedural → episodic
    |> Graph.link("proc_pool", "ep_1")
    |> Graph.link("proc_pool", "ep_2")
  end

  defp candidate_ids(result) do
    result.candidates
    |> Map.values()
    |> List.flatten()
    |> Enum.map(fn {node, _} -> NodeProtocol.id(node) end)
  end

  describe "retrieval with provenance edges" do
    test "semantic search returns semantic nodes from provenance-linked graph" do
      graph = build_provenance_graph()
      stub_retrieval_llm("semantic", "pooling\nperformance")
      stub_default_embedding()

      {:ok, result, _trace} =
        Retrieval.retrieve(
          "How does connection pooling work?",
          retrieval_opts(graph, max_hops: 2)
        )

      assert result.mode == :semantic
      ids = candidate_ids(result)
      assert "sem_pool" in ids
      assert "sem_throughput" in ids
      refute "ep_1" in ids
      refute "ep_2" in ids
    end

    test "procedural search returns procedural nodes from provenance-linked graph" do
      graph = build_provenance_graph()
      stub_retrieval_llm("procedural", "scale database")
      stub_default_embedding()

      {:ok, result, _trace} =
        Retrieval.retrieve("How to scale database?", retrieval_opts(graph, max_hops: 2))

      assert result.mode == :procedural
      ids = candidate_ids(result)
      assert "proc_pool" in ids
      refute "int_scale" in ids
      refute "ep_1" in ids
    end

    test "episodic search retrieves episodic nodes and source provenance" do
      graph = build_provenance_graph()
      stub_retrieval_llm("episodic", "server crash\nstability")
      stub_default_embedding()

      {:ok, result, _trace} =
        Retrieval.retrieve(
          "What happened when server crashed?",
          retrieval_opts(graph, max_hops: 2)
        )

      assert result.mode == :episodic
      ids = candidate_ids(result)
      assert "ep_1" in ids or "ep_2" in ids
      assert "src_1" in ids or "src_2" in ids
    end

    test "semantic candidates carry provenance links to episodic nodes" do
      graph = build_provenance_graph()
      stub_retrieval_llm("semantic", "pooling")
      stub_default_embedding()

      {:ok, result, _trace} =
        Retrieval.retrieve("pooling facts", retrieval_opts(graph, max_hops: 2))

      semantic_nodes =
        result.candidates
        |> Map.get(:semantic, [])
        |> Enum.map(fn {node, _} -> node end)

      assert semantic_nodes != []

      Enum.each(semantic_nodes, fn node ->
        episodic_links =
          node.links
          |> MapSet.to_list()
          |> Enum.filter(&String.starts_with?(&1, "ep_"))

        assert episodic_links != [],
               "semantic node #{node.id} should have provenance links to episodic nodes"
      end)
    end

    test "procedural candidates carry provenance links to episodic nodes" do
      graph = build_provenance_graph()
      stub_retrieval_llm("procedural", "scale database")
      stub_default_embedding()

      {:ok, result, _trace} =
        Retrieval.retrieve("how to scale", retrieval_opts(graph, max_hops: 2))

      procedural_nodes =
        result.candidates
        |> Map.get(:procedural, [])
        |> Enum.map(fn {node, _} -> node end)

      assert procedural_nodes != []

      Enum.each(procedural_nodes, fn node ->
        episodic_links =
          node.links
          |> MapSet.to_list()
          |> Enum.filter(&String.starts_with?(&1, "ep_"))

        assert episodic_links != [],
               "procedural node #{node.id} should have provenance links to episodic nodes"
      end)
    end
  end

  describe "expand_through_routing_nodes/4" do
    test "discovers sibling semantic nodes through shared tags" do
      graph = build_routing_test_graph()
      backend = {InMemory, %InMemory{graph: graph}}
      candidates = [{Graph.get_node(graph, "sem_pasta"), 0.9}]
      seen = MapSet.new(["sem_pasta"])

      siblings = Retrieval.expand_through_routing_nodes(candidates, backend, seen, [:tag])
      sibling_ids = Enum.map(siblings, &NodeProtocol.id/1)

      assert "sem_risotto" in sibling_ids
      assert "sem_sushi" in sibling_ids
      refute "sem_pasta" in sibling_ids
    end

    test "discovers sibling procedural nodes through shared intents" do
      graph = build_routing_test_graph()
      backend = {InMemory, %InMemory{graph: graph}}
      candidates = [{Graph.get_node(graph, "proc_migrate"), 0.9}]
      seen = MapSet.new(["proc_migrate"])

      siblings = Retrieval.expand_through_routing_nodes(candidates, backend, seen, [:intent])
      sibling_ids = Enum.map(siblings, &NodeProtocol.id/1)

      assert "proc_rollback" in sibling_ids
      refute "proc_migrate" in sibling_ids
    end

    test "excludes routing nodes from results" do
      graph = build_routing_test_graph()
      backend = {InMemory, %InMemory{graph: graph}}
      candidates = [{Graph.get_node(graph, "sem_pasta"), 0.9}]
      seen = MapSet.new(["sem_pasta"])

      siblings = Retrieval.expand_through_routing_nodes(candidates, backend, seen, [:tag])
      sibling_types = Enum.map(siblings, &NodeProtocol.node_type/1)

      refute :tag in sibling_types
    end

    test "returns empty list when no routing neighbors exist" do
      graph = build_routing_test_graph()
      backend = {InMemory, %InMemory{graph: graph}}
      candidates = [{Graph.get_node(graph, "src_orphan"), 0.5}]
      seen = MapSet.new(["src_orphan"])

      assert [] == Retrieval.expand_through_routing_nodes(candidates, backend, seen, [:tag])
    end

    test "returns empty list for empty candidates" do
      graph = build_routing_test_graph()
      backend = {InMemory, %InMemory{graph: graph}}

      assert [] == Retrieval.expand_through_routing_nodes([], backend, MapSet.new(), [:tag])
    end
  end

  describe "abstraction-specificity interleaving" do
    test "hop discovers siblings through shared tag that hop 0 missed" do
      query_vec = List.duplicate(0.5, 128)
      close_vec = List.duplicate(0.49, 128)
      far_vec = List.duplicate(-0.3, 128)
      tag_vec = List.duplicate(0.1, 128)

      graph =
        Graph.new()
        |> Graph.put_node(%Semantic{
          id: "sem_close",
          proposition: "Close match",
          confidence: 0.9,
          embedding: close_vec
        })
        |> Graph.put_node(%Semantic{
          id: "sem_far",
          proposition: "Far but related",
          confidence: 0.9,
          embedding: far_vec
        })
        |> Graph.put_node(%Tag{
          id: "tag_shared",
          label: "shared_concept",
          embedding: tag_vec
        })
        |> Graph.link("tag_shared", "sem_close")
        |> Graph.link("tag_shared", "sem_far")

      stub_retrieval_llm("semantic", "shared_concept")

      Mnemosyne.MockEmbedding
      |> stub(:embed, fn _text, _opts ->
        {:ok, %Embedding.Response{vectors: [query_vec], model: "mock", usage: %{}}}
      end)
      |> stub(:embed_batch, fn texts, _opts ->
        vectors = Enum.map(texts, fn _ -> query_vec end)
        {:ok, %Embedding.Response{vectors: vectors, model: "mock", usage: %{}}}
      end)

      {:ok, result, _trace} =
        Retrieval.retrieve("Find related facts", retrieval_opts(graph, max_hops: 2))

      all_ids =
        result.candidates
        |> Map.values()
        |> List.flatten()
        |> Enum.map(fn {node, _} -> node.id end)

      assert "sem_close" in all_ids
      assert "sem_far" in all_ids
    end

    test "mixed mode routes through both tags and intents" do
      query_vec = List.duplicate(0.5, 128)
      close_vec = List.duplicate(0.49, 128)
      far_vec = List.duplicate(-0.3, 128)
      tag_vec = List.duplicate(0.1, 128)

      graph =
        Graph.new()
        |> Graph.put_node(%Semantic{
          id: "sem_a",
          proposition: "A fact",
          confidence: 0.9,
          embedding: close_vec
        })
        |> Graph.put_node(%Semantic{
          id: "sem_b",
          proposition: "Related fact",
          confidence: 0.9,
          embedding: far_vec
        })
        |> Graph.put_node(%Tag{id: "tag_x", label: "concept", embedding: tag_vec})
        |> Graph.put_node(%Procedural{
          id: "proc_a",
          instruction: "Do X",
          condition: "when Y",
          expected_outcome: "Z",
          embedding: close_vec
        })
        |> Graph.put_node(%Procedural{
          id: "proc_b",
          instruction: "Do A",
          condition: "when B",
          expected_outcome: "C",
          embedding: far_vec
        })
        |> Graph.put_node(%Intent{
          id: "int_x",
          description: "Goal",
          embedding: tag_vec
        })
        |> Graph.link("tag_x", "sem_a")
        |> Graph.link("tag_x", "sem_b")
        |> Graph.link("int_x", "proc_a")
        |> Graph.link("int_x", "proc_b")

      stub_retrieval_llm("mixed", "concept\ngoal")

      Mnemosyne.MockEmbedding
      |> stub(:embed, fn _t, _o ->
        {:ok, %Embedding.Response{vectors: [query_vec], model: "m", usage: %{}}}
      end)
      |> stub(:embed_batch, fn ts, _o ->
        {:ok,
         %Embedding.Response{vectors: Enum.map(ts, fn _ -> query_vec end), model: "m", usage: %{}}}
      end)

      {:ok, result, _trace} =
        Retrieval.retrieve("Everything", retrieval_opts(graph, max_hops: 2))

      all_ids =
        result.candidates
        |> Map.values()
        |> List.flatten()
        |> Enum.map(fn {n, _} -> n.id end)

      assert "sem_b" in all_ids
      assert "proc_b" in all_ids
    end

    test "routing nodes never appear in final candidates" do
      graph = build_test_graph()
      stub_retrieval_llm("semantic", "deployment")
      stub_default_embedding()

      {:ok, result, _trace} =
        Retrieval.retrieve("deployment", retrieval_opts(graph, max_hops: 2))

      all_types =
        result.candidates
        |> Map.values()
        |> List.flatten()
        |> Enum.map(fn {node, _} -> NodeProtocol.node_type(node) end)

      refute :tag in all_types
      refute :intent in all_types
    end
  end

  describe "retrieve/2" do
    test "returns retrieval result with mode, tags, and candidates" do
      graph = build_test_graph()
      stub_retrieval_llm()
      stub_default_embedding()

      assert {:ok, %Retrieval.Result{} = result, %Mnemosyne.Notifier.Trace.Recall{}} =
               Retrieval.retrieve("Tell me about Elixir", retrieval_opts(graph))

      assert result.mode == :semantic
      assert ["BEAM VM", "fault tolerance"] = result.tags
      assert is_map(result.candidates)
    end

    test "semantic mode retrieves semantic nodes" do
      graph = build_test_graph()
      stub_retrieval_llm("semantic")
      stub_default_embedding()

      {:ok, result, _trace} = Retrieval.retrieve("What is BEAM?", retrieval_opts(graph))

      assert result.mode == :semantic
      candidate_types = Map.keys(result.candidates)
      assert :semantic in candidate_types
      refute :tag in candidate_types
    end

    test "episodic mode retrieves episodic nodes and expands provenance" do
      graph = build_test_graph()
      stub_retrieval_llm("episodic", "server crash\nservice recovery")
      stub_default_embedding()

      {:ok, result, _trace} =
        Retrieval.retrieve("What happened during the outage?", retrieval_opts(graph))

      assert result.mode == :episodic
      candidate_types = Map.keys(result.candidates)
      assert :episodic in candidate_types
    end

    test "procedural mode retrieves procedural nodes" do
      graph = build_test_graph()
      stub_retrieval_llm("procedural", "deployment\nmigrations")
      stub_default_embedding()

      {:ok, result, _trace} = Retrieval.retrieve("How do I deploy?", retrieval_opts(graph))

      assert result.mode == :procedural
      candidate_types = Map.keys(result.candidates)
      assert :procedural in candidate_types
    end

    test "mixed mode retrieves all node types" do
      graph = build_test_graph()
      stub_retrieval_llm("mixed", "Elixir\ndeployment")
      stub_default_embedding()

      {:ok, result, _trace} = Retrieval.retrieve("Tell me everything", retrieval_opts(graph))

      assert result.mode == :mixed
    end

    test "max_hops 0 returns only hop-0 results without traversal" do
      graph = build_test_graph()
      stub_retrieval_llm("semantic")
      stub_default_embedding()

      {:ok, result, _trace} =
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

      {:ok, result, _trace} =
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

      {:ok, result, _trace} = Retrieval.retrieve("anything", retrieval_opts(graph))

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

      assert {:ok, %Retrieval.Result{}, %Mnemosyne.Notifier.Trace.Recall{}} =
               Retrieval.retrieve("test", opts)
    end

    test "procedural mode discovers prescriptions through intent nodes" do
      graph = build_test_graph()
      stub_retrieval_llm("procedural", "deploy safely")
      stub_default_embedding()

      {:ok, result, _trace} =
        Retrieval.retrieve("How do I deploy safely?", retrieval_opts(graph, max_hops: 2))

      all_ids =
        result.candidates
        |> Map.values()
        |> List.flatten()
        |> Enum.map(fn {node, _score} -> node.id end)

      assert "proc_1" in all_ids
      refute "int_1" in all_ids
    end

    test "semantic mode discovers propositions through concept tags" do
      graph = build_test_graph()
      stub_retrieval_llm("semantic", "deployment")
      stub_default_embedding()

      {:ok, result, _trace} =
        Retrieval.retrieve("What about deployment?", retrieval_opts(graph, max_hops: 2))

      all_ids =
        result.candidates
        |> Map.values()
        |> List.flatten()
        |> Enum.map(fn {node, _score} -> node.id end)

      assert "sem_1" in all_ids
      refute "tag_1" in all_ids
    end

    test "candidates include scores as floats" do
      graph = build_test_graph()
      stub_retrieval_llm()
      stub_default_embedding()

      {:ok, result, _trace} = Retrieval.retrieve("Elixir BEAM", retrieval_opts(graph))

      result.candidates
      |> Map.values()
      |> List.flatten()
      |> Enum.each(fn {_node, score} ->
        assert is_float(score)
      end)
    end
  end

  describe "query refinement" do
    @orthogonal_vector List.duplicate(-0.1, 128)

    defp build_low_similarity_graph do
      Graph.new()
      |> Graph.put_node(%Semantic{
        id: "sem_weak",
        proposition: "Barely related fact",
        confidence: 0.5,
        embedding: @orthogonal_vector
      })
      |> Graph.put_node(%Semantic{
        id: "sem_refined",
        proposition: "Actually relevant fact",
        confidence: 0.9,
        embedding: @alt_vector
      })
      |> Graph.put_node(%Tag{
        id: "tag_weak",
        label: "weak concept",
        embedding: @orthogonal_vector
      })
      |> Graph.link("tag_weak", "sem_weak")
    end

    defp refinement_config(threshold) do
      %Config{
        llm: %{model: "test:model", opts: %{}},
        embedding: %{model: "test:embed", opts: %{}},
        value_function: %{module: Mnemosyne.ValueFunction.Default, params: %{}},
        refinement_threshold: threshold
      }
    end

    test "triggers refinement when best relevance is below threshold" do
      graph = build_low_similarity_graph()
      config = refinement_config(0.99)

      stub_retrieval_llm("semantic", "weak concept")

      Mnemosyne.MockEmbedding
      |> stub(:embed, fn _text, _opts ->
        {:ok, %Embedding.Response{vectors: [@test_vector], model: "mock:embed", usage: %{}}}
      end)
      |> stub(:embed_batch, fn _texts, _opts ->
        {:ok, %Embedding.Response{vectors: [@test_vector], model: "mock:embed", usage: %{}}}
      end)

      Mnemosyne.MockLLM
      |> stub(:chat_structured, fn _messages, _schema, _opts ->
        {:ok, %LLM.Response{content: %{tags: ["refined tag"]}, model: "mock:test", usage: %{}}}
      end)

      {:ok, result, _trace} =
        Retrieval.retrieve(
          "Find something specific",
          retrieval_opts(graph, config: config, max_hops: 1)
        )

      assert result.mode == :semantic
    end

    test "skips refinement when best relevance is above threshold" do
      graph = build_test_graph()
      config = refinement_config(0.1)

      stub_retrieval_llm("semantic", "BEAM VM")

      Mnemosyne.MockEmbedding
      |> stub(:embed, fn _text, _opts ->
        {:ok, %Embedding.Response{vectors: [@test_vector], model: "mock:embed", usage: %{}}}
      end)
      |> stub(:embed_batch, fn _texts, _opts ->
        {:ok, %Embedding.Response{vectors: [@test_vector], model: "mock:embed", usage: %{}}}
      end)

      Mnemosyne.MockLLM
      |> reject(:chat_structured, 3)

      {:ok, result, _trace} =
        Retrieval.retrieve(
          "Tell me about Elixir",
          retrieval_opts(graph, config: config, max_hops: 1)
        )

      assert result.mode == :semantic
    end

    test "handles empty refined tags gracefully" do
      graph = build_low_similarity_graph()
      config = refinement_config(0.99)

      stub_retrieval_llm("semantic", "weak concept")

      Mnemosyne.MockEmbedding
      |> stub(:embed, fn _text, _opts ->
        {:ok, %Embedding.Response{vectors: [@test_vector], model: "mock:embed", usage: %{}}}
      end)
      |> stub(:embed_batch, fn _texts, _opts ->
        {:ok, %Embedding.Response{vectors: [@test_vector], model: "mock:embed", usage: %{}}}
      end)

      Mnemosyne.MockLLM
      |> stub(:chat_structured, fn _messages, _schema, _opts ->
        {:ok, %LLM.Response{content: %{tags: []}, model: "mock:test", usage: %{}}}
      end)

      {:ok, result, _trace} =
        Retrieval.retrieve(
          "Find something",
          retrieval_opts(graph, config: config, max_hops: 1)
        )

      assert result.mode == :semantic
      assert is_map(result.candidates)
    end

    test "handles refinement LLM error gracefully" do
      graph = build_low_similarity_graph()
      config = refinement_config(0.99)

      stub_retrieval_llm("semantic", "weak concept")

      Mnemosyne.MockEmbedding
      |> stub(:embed, fn _text, _opts ->
        {:ok, %Embedding.Response{vectors: [@test_vector], model: "mock:embed", usage: %{}}}
      end)
      |> stub(:embed_batch, fn _texts, _opts ->
        {:ok, %Embedding.Response{vectors: [@test_vector], model: "mock:embed", usage: %{}}}
      end)

      Mnemosyne.MockLLM
      |> stub(:chat_structured, fn _messages, _schema, _opts ->
        {:error, :llm_unavailable}
      end)

      {:ok, result, _trace} =
        Retrieval.retrieve(
          "Find something",
          retrieval_opts(graph, config: config, max_hops: 1)
        )

      assert result.mode == :semantic
    end
  end
end
