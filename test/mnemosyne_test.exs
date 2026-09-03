defmodule MnemosyneTest do
  use ExUnit.Case, async: false
  use AssertEventually, timeout: 500, interval: 10

  import Mimic

  alias Mnemosyne.Embedding
  alias Mnemosyne.Errors.Framework.NotFoundError
  alias Mnemosyne.Errors.Invalid.IngestionError
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Procedural
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.GraphBackends.Persistence.DETS
  alias Mnemosyne.IngestionReceipt
  alias Mnemosyne.LLM
  alias Mnemosyne.NodeMetadata
  alias Mnemosyne.Pipeline.Reasoning.ReasonedMemory
  alias Mnemosyne.Pipeline.RecallResult
  alias Mnemosyne.Trajectory

  @moduletag :tmp_dir

  setup :set_mimic_global

  defp stub_extraction_success do
    stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
      {:ok, %LLM.Response{content: "0.5", model: "test", usage: %{}}}
    end)

    stub(Mnemosyne.MockLLM, :chat_structured, fn messages, _schema, _opts ->
      system_content =
        messages
        |> Enum.find(%{content: ""}, &(&1.role == :system))
        |> Map.get(:content, "")

      content =
        cond do
          String.contains?(system_content, "subgoal") ->
            %{reasoning: "analysis", subgoal: "test subgoal"}

          String.contains?(system_content, "factual knowledge") ->
            %{facts: [%{proposition: "some fact", concepts: ["concept1", "concept2"]}]}

          String.contains?(system_content, "actionable instructions") ->
            %{
              instructions: [
                %{
                  intent: "goal",
                  condition: "condition",
                  instruction: "action",
                  expected_outcome: "outcome"
                }
              ]
            }

          String.contains?(system_content, "prescription quality") ->
            %{scores: [%{index: 0, return_score: 8}]}

          true ->
            %{}
        end

      {:ok, %LLM.Response{content: content, model: "test", usage: %{}}}
    end)

    stub(Mnemosyne.MockEmbedding, :embed, fn _text, _opts ->
      {:ok, %Embedding.Response{vectors: [List.duplicate(0.1, 128)], model: "test", usage: %{}}}
    end)

    stub(Mnemosyne.MockEmbedding, :embed_batch, fn texts, _opts ->
      vectors = Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)
      {:ok, %Embedding.Response{vectors: vectors, model: "test", usage: %{}}}
    end)
  end

  defp stub_recall_success do
    stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
      {:ok, %LLM.Response{content: "semantic", model: "test", usage: %{}}}
    end)

    stub(Mnemosyne.MockLLM, :chat_structured, fn _messages, _schema, _opts ->
      {:ok,
       %LLM.Response{
         content: %{reasoning: "analysis", information: "Summary."},
         model: "test",
         usage: %{}
       }}
    end)

    stub(Mnemosyne.MockEmbedding, :embed, fn _text, _opts ->
      {:ok, %Embedding.Response{vectors: [List.duplicate(0.1, 128)], model: "test", usage: %{}}}
    end)

    stub(Mnemosyne.MockEmbedding, :embed_batch, fn texts, _opts ->
      vectors = Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)
      {:ok, %Embedding.Response{vectors: vectors, model: "test", usage: %{}}}
    end)
  end

  defp stub_recall_query_capture(test_pid) do
    stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
      {:ok, %LLM.Response{content: "semantic", model: "test", usage: %{}}}
    end)

    stub(Mnemosyne.MockLLM, :chat_structured, fn messages, _schema, _opts ->
      user_content = messages |> List.last() |> Map.fetch!(:content)
      [_, query] = Regex.run(~r/Query: (.*?)\n\nKnown Facts:/s, user_content)
      send(test_pid, {:reasoning_query, query})

      {:ok,
       %LLM.Response{
         content: %{reasoning: "analysis", information: "Summary."},
         model: "test",
         usage: %{}
       }}
    end)

    stub(Mnemosyne.MockEmbedding, :embed, fn _text, _opts ->
      {:ok, %Embedding.Response{vectors: [List.duplicate(0.1, 128)], model: "test", usage: %{}}}
    end)

    stub(Mnemosyne.MockEmbedding, :embed_batch, fn [query | _tags] = texts, _opts ->
      send(test_pid, {:retrieval_query, query})
      vectors = Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)
      {:ok, %Embedding.Response{vectors: vectors, model: "test", usage: %{}}}
    end)
  end

  defp build_config do
    {:ok, config} =
      Zoi.parse(Mnemosyne.Config.t(), %{
        llm: %{model: "test-model", opts: %{}},
        embedding: %{model: "test-embed", opts: %{}}
      })

    config
  end

  defp start_supervisor(_tmp_dir, opts \\ []) do
    opts =
      Keyword.merge(
        [
          config: build_config(),
          llm: Mnemosyne.MockLLM,
          embedding: Mnemosyne.MockEmbedding
        ],
        opts
      )

    start_supervised!({Mnemosyne.Supervisor, opts})
  end

  defp open_test_repo(tmp_dir, opts \\ []) do
    repo_id = Keyword.get(opts, :repo_id, "test-repo-#{System.unique_integer([:positive])}")
    dets_path = Path.join(tmp_dir, "#{repo_id}.dets")
    persistence = {DETS, path: dets_path}

    {:ok, _pid} =
      Mnemosyne.open_repo(repo_id,
        backend: {InMemory, persistence: persistence},
        supervisor: Keyword.get(opts, :supervisor, Mnemosyne.Supervisor)
      )

    repo_id
  end

  defp trajectory(overrides \\ []) do
    struct!(
      Trajectory,
      Keyword.merge(
        [
          source_id: "source-#{System.unique_integer([:positive])}",
          goal: "Diagnose timeouts",
          steps: [%{observation: "Timeout", action: "Inspect logs"}],
          metadata: %{}
        ],
        overrides
      )
    )
  end

  describe "ingest/3" do
    test "stores a trajectory and exposes its graph nodes on return", %{tmp_dir: tmp_dir} do
      stub_extraction_success()
      start_supervisor(tmp_dir)
      repo = open_test_repo(tmp_dir)

      assert {:ok, %IngestionReceipt{node_ids: node_ids}} = Mnemosyne.ingest(repo, trajectory())
      assert node_ids != []

      graph = Mnemosyne.get_graph(repo)
      assert Enum.all?(node_ids, &Map.has_key?(graph.nodes, &1))
    end

    test "returns a repo not-found error", %{tmp_dir: tmp_dir} do
      start_supervisor(tmp_dir)

      assert {:error, %NotFoundError{resource: :repo, id: "missing-repo"}} =
               Mnemosyne.ingest("missing-repo", trajectory())
    end

    test "uses its supervisor only for lookup and forwards execution overrides", %{
      tmp_dir: tmp_dir
    } do
      test_pid = self()
      supervisor = :"ingestion_supervisor_#{System.unique_integer([:positive])}"
      override_config = %{build_config() | llm: %{model: "override", opts: %{}}}

      changeset =
        Changeset.add_node(
          Changeset.new(),
          %Semantic{id: "override", proposition: "Stored", confidence: 0.9}
        )

      stub(Mnemosyne.Pipeline.Ingestion, :run, fn _trajectory, opts ->
        send(test_pid, {:ingestion_execution_opts, opts})
        {:ok, changeset}
      end)

      start_supervisor(tmp_dir, name: supervisor)
      repo = open_test_repo(tmp_dir, supervisor: supervisor)

      assert {:ok, %IngestionReceipt{node_ids: ["override"]}} =
               Mnemosyne.ingest(repo, trajectory(),
                 supervisor: supervisor,
                 config: override_config,
                 llm: __MODULE__,
                 embedding: __MODULE__,
                 llm_opts: [temperature: 0.0],
                 embedding_opts: [normalize: true]
               )

      assert_receive {:ingestion_execution_opts, opts}
      assert opts[:config] == override_config
      assert opts[:llm] == __MODULE__
      assert opts[:embedding] == __MODULE__
      assert opts[:llm_opts] == [temperature: 0.0]
      assert opts[:embedding_opts] == [normalize: true]
      assert opts[:repo_id] == repo
      refute Keyword.has_key?(opts, :supervisor)
    end

    test "returns its persisted receipt for an equal retry and rejects conflicts", %{
      tmp_dir: tmp_dir
    } do
      stub_extraction_success()
      start_supervisor(tmp_dir)
      repo = open_test_repo(tmp_dir)
      input = trajectory(source_id: "idempotent-source")

      assert {:ok, receipt} = Mnemosyne.ingest(repo, input)
      assert {:ok, ^receipt} = Mnemosyne.ingest(repo, input, config: build_config())

      assert {:error, %IngestionError{source_id: "idempotent-source", reason: :source_conflict}} =
               Mnemosyne.ingest(repo, %{input | goal: "A different goal"})
    end
  end

  describe "recall/3" do
    test "returns {:ok, %ReasonedMemory{}}", %{tmp_dir: tmp_dir} do
      stub_recall_success()
      start_supervisor(tmp_dir)
      repo = open_test_repo(tmp_dir)

      node = %Semantic{
        id: "s1",
        proposition: "Elixir is functional",
        confidence: 0.9
      }

      changeset = Changeset.add_node(Changeset.new(), node)
      :ok = Mnemosyne.apply_changeset(repo, changeset)

      assert_eventually(Mnemosyne.get_graph(repo).nodes["s1"] != nil)

      assert {:ok, %RecallResult{reasoned: %ReasonedMemory{}}} =
               Mnemosyne.recall(repo, "what is elixir?")
    end

    test "passes formatted caller context to retrieval and reasoning", %{tmp_dir: tmp_dir} do
      test_pid = self()
      start_supervisor(tmp_dir)
      repo = open_test_repo(tmp_dir)

      node = %Semantic{id: "context-node", proposition: "Inspect timeout logs", confidence: 0.9}
      :ok = Mnemosyne.apply_changeset(repo, Changeset.add_node(Changeset.new(), node))
      assert_eventually(Mnemosyne.get_graph(repo).nodes["context-node"] != nil)

      stub_recall_query_capture(test_pid)

      context = %{
        goal: "Diagnose intermittent timeouts",
        recent_steps: [
          %{observation: "First observation", action: "First action"},
          %{observation: "Second observation", action: "Second action"},
          %{observation: "Third observation", action: "Third action"},
          %{observation: "Fourth observation", action: "Fourth action"}
        ]
      }

      expected_query =
        "Goal: Diagnose intermittent timeouts\n" <>
          "Recent context:\n" <>
          "- Second observation -> Second action\n" <>
          "- Third observation -> Third action\n" <>
          "- Fourth observation -> Fourth action\n\n" <>
          "Query: What should I try next?"

      assert {:ok, %RecallResult{reasoned: %ReasonedMemory{}} = result} =
               Mnemosyne.recall(repo, "What should I try next?",
                 context: context,
                 source_id: "active-task",
                 max_hops: 0
               )

      assert result.trace.source_id == "active-task"
      assert_received {:retrieval_query, ^expected_query}
      assert_received {:reasoning_query, ^expected_query}
    end

    test "passes the original query unchanged with explicit nil context", %{tmp_dir: tmp_dir} do
      test_pid = self()
      start_supervisor(tmp_dir)
      repo = open_test_repo(tmp_dir)

      node = %Semantic{id: "plain-node", proposition: "Plain recall", confidence: 0.9}
      :ok = Mnemosyne.apply_changeset(repo, Changeset.add_node(Changeset.new(), node))
      assert_eventually(Mnemosyne.get_graph(repo).nodes["plain-node"] != nil)
      stub_recall_query_capture(test_pid)

      assert {:ok, %RecallResult{reasoned: %ReasonedMemory{}}} =
               Mnemosyne.recall(repo, "Unchanged query", context: nil, max_hops: 0)

      assert_received {:retrieval_query, "Unchanged query"}
      assert_received {:reasoning_query, "Unchanged query"}
    end

    test "returns error when repo does not exist", %{tmp_dir: tmp_dir} do
      start_supervisor(tmp_dir)

      assert {:error, %NotFoundError{resource: :repo}} =
               Mnemosyne.recall("nonexistent", "query")
    end
  end

  describe "management" do
    test "apply_changeset adds nodes to graph", %{tmp_dir: tmp_dir} do
      start_supervisor(tmp_dir)
      repo = open_test_repo(tmp_dir)

      node = %Semantic{
        id: "mgmt-1",
        proposition: "Test fact",
        confidence: 0.9
      }

      changeset = Changeset.add_node(Changeset.new(), node)
      assert :ok = Mnemosyne.apply_changeset(repo, changeset)

      assert_eventually(Mnemosyne.get_graph(repo).nodes["mgmt-1"] != nil)
    end

    test "delete_nodes removes nodes from graph", %{tmp_dir: tmp_dir} do
      start_supervisor(tmp_dir)
      repo = open_test_repo(tmp_dir)

      node = %Semantic{
        id: "del-1",
        proposition: "To delete",
        confidence: 0.9
      }

      changeset = Changeset.add_node(Changeset.new(), node)
      :ok = Mnemosyne.apply_changeset(repo, changeset)

      assert_eventually(Mnemosyne.get_graph(repo).nodes["del-1"] != nil)

      assert :ok = Mnemosyne.delete_nodes(repo, ["del-1"])

      assert_eventually(Mnemosyne.get_graph(repo).nodes["del-1"] == nil)
    end

    test "apply_changeset returns error when repo does not exist", %{tmp_dir: tmp_dir} do
      start_supervisor(tmp_dir)
      changeset = Changeset.new()

      assert {:error, %NotFoundError{resource: :repo}} =
               Mnemosyne.apply_changeset("nonexistent", changeset)
    end

    test "delete_nodes returns error when repo does not exist", %{tmp_dir: tmp_dir} do
      start_supervisor(tmp_dir)

      assert {:error, %NotFoundError{resource: :repo}} =
               Mnemosyne.delete_nodes("nonexistent", ["id"])
    end

    test "get_graph returns error when repo does not exist", %{tmp_dir: tmp_dir} do
      start_supervisor(tmp_dir)

      assert {:error, %NotFoundError{resource: :repo}} =
               Mnemosyne.get_graph("nonexistent")
    end
  end

  describe "consolidate_semantics/2" do
    test "accepts request without error", %{tmp_dir: tmp_dir} do
      start_supervisor(tmp_dir)
      repo = open_test_repo(tmp_dir)

      assert :ok = Mnemosyne.consolidate_semantics(repo)
    end

    test "returns error when repo does not exist", %{tmp_dir: tmp_dir} do
      start_supervisor(tmp_dir)

      assert {:error, %NotFoundError{resource: :repo}} =
               Mnemosyne.consolidate_semantics("nonexistent")
    end
  end

  describe "decay_nodes/2" do
    test "accepts request without error", %{tmp_dir: tmp_dir} do
      start_supervisor(tmp_dir)
      repo = open_test_repo(tmp_dir)

      assert :ok = Mnemosyne.decay_nodes(repo)
    end

    test "returns error when repo does not exist", %{tmp_dir: tmp_dir} do
      start_supervisor(tmp_dir)

      assert {:error, %NotFoundError{resource: :repo}} =
               Mnemosyne.decay_nodes("nonexistent")
    end
  end

  describe "latest/3" do
    test "returns nodes sorted by created_at descending", %{tmp_dir: tmp_dir} do
      start_supervisor(tmp_dir)
      repo = open_test_repo(tmp_dir)

      old_time = ~U[2025-01-01 00:00:00Z]
      mid_time = ~U[2025-06-01 00:00:00Z]
      new_time = ~U[2026-01-01 00:00:00Z]

      nodes = [
        %Semantic{id: "s-old", proposition: "Old fact", confidence: 0.9},
        %Semantic{id: "s-mid", proposition: "Mid fact", confidence: 0.9},
        %Semantic{id: "s-new", proposition: "New fact", confidence: 0.9}
      ]

      changeset =
        nodes
        |> Enum.zip([old_time, mid_time, new_time])
        |> Enum.reduce(Changeset.new(), fn {node, ts}, cs ->
          cs
          |> Changeset.add_node(node)
          |> Changeset.put_metadata(node.id, NodeMetadata.new(created_at: ts))
        end)

      :ok = Mnemosyne.apply_changeset(repo, changeset)
      assert_eventually(Mnemosyne.get_graph(repo).nodes["s-old"] != nil)

      assert {:ok, results} = Mnemosyne.latest(repo, 10)

      ids = Enum.map(results, fn {node, _meta} -> node.id end)
      assert ids == ["s-new", "s-mid", "s-old"]
    end

    test "respects top_k limit", %{tmp_dir: tmp_dir} do
      start_supervisor(tmp_dir)
      repo = open_test_repo(tmp_dir)

      changeset =
        Enum.reduce(1..5, Changeset.new(), fn i, cs ->
          node = %Semantic{id: "s-#{i}", proposition: "Fact #{i}", confidence: 0.9}
          ts = DateTime.add(~U[2025-01-01 00:00:00Z], i, :day)

          cs
          |> Changeset.add_node(node)
          |> Changeset.put_metadata(node.id, NodeMetadata.new(created_at: ts))
        end)

      :ok = Mnemosyne.apply_changeset(repo, changeset)
      assert_eventually(Mnemosyne.get_graph(repo).nodes["s-5"] != nil)

      assert {:ok, results} = Mnemosyne.latest(repo, 2)
      assert length(results) == 2
    end

    test "returns both semantic and procedural nodes by default", %{tmp_dir: tmp_dir} do
      start_supervisor(tmp_dir)
      repo = open_test_repo(tmp_dir)

      sem = %Semantic{id: "sem-1", proposition: "A fact", confidence: 0.9}

      proc = %Procedural{
        id: "proc-1",
        instruction: "Do this",
        condition: "When that",
        expected_outcome: "Then result"
      }

      changeset =
        Changeset.new()
        |> Changeset.add_node(sem)
        |> Changeset.put_metadata("sem-1", NodeMetadata.new(created_at: ~U[2025-01-01 00:00:00Z]))
        |> Changeset.add_node(proc)
        |> Changeset.put_metadata(
          "proc-1",
          NodeMetadata.new(created_at: ~U[2025-06-01 00:00:00Z])
        )

      :ok = Mnemosyne.apply_changeset(repo, changeset)
      assert_eventually(Mnemosyne.get_graph(repo).nodes["proc-1"] != nil)

      assert {:ok, results} = Mnemosyne.latest(repo, 10)
      types = Enum.map(results, fn {node, _meta} -> Mnemosyne.Graph.Node.node_type(node) end)
      assert :semantic in types
      assert :procedural in types
    end

    test "filters by custom types", %{tmp_dir: tmp_dir} do
      start_supervisor(tmp_dir)
      repo = open_test_repo(tmp_dir)

      sem = %Semantic{id: "sem-2", proposition: "A fact", confidence: 0.9}

      proc = %Procedural{
        id: "proc-2",
        instruction: "Do this",
        condition: "When that",
        expected_outcome: "Then result"
      }

      changeset =
        Changeset.new()
        |> Changeset.add_node(sem)
        |> Changeset.put_metadata("sem-2", NodeMetadata.new(created_at: ~U[2025-01-01 00:00:00Z]))
        |> Changeset.add_node(proc)
        |> Changeset.put_metadata(
          "proc-2",
          NodeMetadata.new(created_at: ~U[2025-06-01 00:00:00Z])
        )

      :ok = Mnemosyne.apply_changeset(repo, changeset)
      assert_eventually(Mnemosyne.get_graph(repo).nodes["sem-2"] != nil)

      assert {:ok, results} = Mnemosyne.latest(repo, 10, types: [:procedural])

      assert [{"proc-2", :procedural}] ==
               Enum.map(results, fn {node, _} ->
                 {node.id, Mnemosyne.Graph.Node.node_type(node)}
               end)
    end

    test "returns empty list for empty repo", %{tmp_dir: tmp_dir} do
      start_supervisor(tmp_dir)
      repo = open_test_repo(tmp_dir)

      assert {:ok, []} = Mnemosyne.latest(repo, 10)
    end

    test "returns error when repo does not exist", %{tmp_dir: tmp_dir} do
      start_supervisor(tmp_dir)

      assert {:error, %NotFoundError{resource: :repo}} =
               Mnemosyne.latest("nonexistent", 10)
    end
  end
end
