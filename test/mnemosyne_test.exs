defmodule MnemosyneTest do
  use ExUnit.Case, async: false
  use AssertEventually, timeout: 500, interval: 10

  import Mimic

  alias Mnemosyne.Embedding
  alias Mnemosyne.Errors.Framework.NotFoundError
  alias Mnemosyne.Errors.Framework.PipelineError
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Procedural
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.GraphBackends.Persistence.DETS
  alias Mnemosyne.LLM
  alias Mnemosyne.NodeMetadata
  alias Mnemosyne.Pipeline.Reasoning.ReasonedMemory
  alias Mnemosyne.Pipeline.RecallResult

  @moduletag :tmp_dir

  setup :set_mimic_global

  defp stub_llm_for_episode do
    stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
      {:ok, %LLM.Response{content: "0.5", model: "test", usage: %{}}}
    end)

    stub(Mnemosyne.MockLLM, :chat_structured, fn _messages, _schema, _opts ->
      {:ok,
       %LLM.Response{
         content: %{"reasoning" => "analysis", "subgoal" => "test subgoal"},
         model: "test",
         usage: %{}
       }}
    end)

    stub(Mnemosyne.MockEmbedding, :embed, fn _text, _opts ->
      {:ok, %Embedding.Response{vectors: [List.duplicate(0.1, 128)], model: "test", usage: %{}}}
    end)
  end

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
            %{"reasoning" => "analysis", "subgoal" => "test subgoal"}

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

  defp build_config do
    {:ok, config} =
      Zoi.parse(Mnemosyne.Config.t(), %{
        llm: %{model: "test-model", opts: %{}},
        embedding: %{model: "test-embed", opts: %{}},
        session: %{auto_commit: false, flush_timeout_ms: :infinity, session_timeout_ms: :infinity}
      })

    config
  end

  defp start_supervisor(_tmp_dir) do
    opts = [
      config: build_config(),
      llm: Mnemosyne.MockLLM,
      embedding: Mnemosyne.MockEmbedding
    ]

    start_supervised!({Mnemosyne.Supervisor, opts})
  end

  defp open_test_repo(tmp_dir, opts \\ []) do
    repo_id = Keyword.get(opts, :repo_id, "test-repo-#{System.unique_integer([:positive])}")
    dets_path = Path.join(tmp_dir, "#{repo_id}.dets")
    persistence = {DETS, path: dets_path}

    {:ok, _pid} = Mnemosyne.open_repo(repo_id, backend: {InMemory, persistence: persistence})
    repo_id
  end

  describe "start_session/2" do
    test "returns {:ok, session_id} with valid string ID", %{tmp_dir: tmp_dir} do
      start_supervisor(tmp_dir)
      repo = open_test_repo(tmp_dir)

      assert {:ok, session_id} = Mnemosyne.start_session("test goal", repo: repo)
      assert is_binary(session_id)
      assert String.starts_with?(session_id, "session_")
    end

    test "returns error when repo does not exist", %{tmp_dir: tmp_dir} do
      start_supervisor(tmp_dir)

      assert {:error, %NotFoundError{resource: :repo}} =
               Mnemosyne.start_session("test goal", repo: "nonexistent")
    end
  end

  describe "session_state/1" do
    test "returns current state of a session", %{tmp_dir: tmp_dir} do
      start_supervisor(tmp_dir)
      repo = open_test_repo(tmp_dir)

      {:ok, session_id} = Mnemosyne.start_session("test goal", repo: repo)
      assert :collecting = Mnemosyne.session_state(session_id)
    end
  end

  describe "full write path" do
    test "start_session -> append -> close_and_commit produces graph nodes", %{tmp_dir: tmp_dir} do
      stub_extraction_success()
      start_supervisor(tmp_dir)
      repo = open_test_repo(tmp_dir)

      {:ok, session_id} = Mnemosyne.start_session("test goal", repo: repo)
      assert :ok = Mnemosyne.append(session_id, "saw something", "did something")
      assert :ok = Mnemosyne.close_and_commit(session_id)

      assert_eventually(map_size(Mnemosyne.get_graph(repo).nodes) > 0)
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

    test "returns error when repo does not exist", %{tmp_dir: tmp_dir} do
      start_supervisor(tmp_dir)

      assert {:error, %NotFoundError{resource: :repo}} =
               Mnemosyne.recall("nonexistent", "query")
    end
  end

  describe "close_and_commit retries" do
    test "retries on transient failure then succeeds", %{tmp_dir: tmp_dir} do
      chat_count = :counters.new(1, [:atomics])
      structured_count = :counters.new(1, [:atomics])

      stub(Mnemosyne.MockLLM, :chat, fn messages, _opts ->
        count = :counters.get(chat_count, 1)
        :counters.add(chat_count, 1, 1)

        system_content =
          messages
          |> Enum.find(%{content: ""}, &(&1.role == :system))
          |> Map.get(:content, "")

        if String.contains?(system_content, "return") and count < 2 do
          {:error, :transient_failure}
        else
          {:ok, %LLM.Response{content: "0.5", model: "test", usage: %{}}}
        end
      end)

      stub(Mnemosyne.MockLLM, :chat_structured, fn messages, _schema, _opts ->
        count = :counters.get(structured_count, 1)
        :counters.add(structured_count, 1, 1)

        system_content =
          messages
          |> Enum.find(%{content: ""}, &(&1.role == :system))
          |> Map.get(:content, "")

        cond do
          String.contains?(system_content, "subgoal") ->
            {:ok,
             %LLM.Response{
               content: %{"reasoning" => "analysis", "subgoal" => "test subgoal"},
               model: "test",
               usage: %{}
             }}

          count < 4 ->
            {:error, :transient_failure}

          String.contains?(system_content, "factual knowledge") ->
            {:ok,
             %LLM.Response{
               content: %{facts: [%{proposition: "a fact", concepts: ["c1", "c2"]}]},
               model: "test",
               usage: %{}
             }}

          String.contains?(system_content, "actionable instructions") ->
            {:ok,
             %LLM.Response{
               content: %{
                 instructions: [
                   %{intent: "goal", condition: "c", instruction: "a", expected_outcome: "o"}
                 ]
               },
               model: "test",
               usage: %{}
             }}

          String.contains?(system_content, "prescription quality") ->
            {:ok,
             %LLM.Response{
               content: %{scores: [%{index: 0, return_score: 8}]},
               model: "test",
               usage: %{}
             }}

          true ->
            {:ok, %LLM.Response{content: %{}, model: "test", usage: %{}}}
        end
      end)

      stub(Mnemosyne.MockEmbedding, :embed, fn _text, _opts ->
        {:ok, %Embedding.Response{vectors: [List.duplicate(0.1, 128)], model: "test", usage: %{}}}
      end)

      stub(Mnemosyne.MockEmbedding, :embed_batch, fn texts, _opts ->
        vectors = Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)
        {:ok, %Embedding.Response{vectors: vectors, model: "test", usage: %{}}}
      end)

      start_supervisor(tmp_dir)
      repo = open_test_repo(tmp_dir)

      {:ok, session_id} = Mnemosyne.start_session("test goal", repo: repo)
      :ok = Mnemosyne.append(session_id, "saw something", "did something")
      assert :ok = Mnemosyne.close_and_commit(session_id, max_retries: 2)
    end

    test "returns error after max retries exhausted", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      start_supervisor(tmp_dir)
      repo = open_test_repo(tmp_dir)

      {:ok, session_id} = Mnemosyne.start_session("test goal", repo: repo)
      :ok = Mnemosyne.append(session_id, "saw something", "did something")

      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        {:error, :permanent_failure}
      end)

      stub(Mnemosyne.MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        {:error, :permanent_failure}
      end)

      stub(Mnemosyne.MockEmbedding, :embed_batch, fn texts, _opts ->
        vectors = Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)
        {:ok, %Embedding.Response{vectors: vectors, model: "test", usage: %{}}}
      end)

      assert {:error, %PipelineError{reason: :extraction_failed}} =
               Mnemosyne.close_and_commit(session_id, max_retries: 1)
    end
  end

  describe "recall_in_context/4" do
    test "augments query with session context and returns ReasonedMemory", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      start_supervisor(tmp_dir)
      repo = open_test_repo(tmp_dir)

      node = %Semantic{
        id: "ctx-1",
        proposition: "Elixir uses pattern matching",
        confidence: 0.9
      }

      changeset = Changeset.add_node(Changeset.new(), node)
      :ok = Mnemosyne.apply_changeset(repo, changeset)

      assert_eventually(Mnemosyne.get_graph(repo).nodes["ctx-1"] != nil)

      {:ok, session_id} = Mnemosyne.start_session("learn elixir", repo: repo)
      :ok = Mnemosyne.append(session_id, "read about pattern matching", "took notes")

      queries_seen = :ets.new(:queries_seen, [:set, :public])

      stub(Mnemosyne.MockEmbedding, :embed, fn text, _opts ->
        :ets.insert(queries_seen, {:query, text})
        {:ok, %Embedding.Response{vectors: [List.duplicate(0.1, 128)], model: "test", usage: %{}}}
      end)

      stub(Mnemosyne.MockEmbedding, :embed_batch, fn texts, _opts ->
        vectors = Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)
        {:ok, %Embedding.Response{vectors: vectors, model: "test", usage: %{}}}
      end)

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

      assert {:ok, %RecallResult{reasoned: %ReasonedMemory{}}} =
               Mnemosyne.recall_in_context(repo, session_id, "what is pattern matching?")

      [{:query, augmented_query}] = :ets.lookup(queries_seen, :query)
      assert augmented_query =~ "learn elixir"
      assert augmented_query =~ "read about pattern matching"
      assert augmented_query =~ "what is pattern matching?"
    end

    test "returns error when repo does not exist", %{tmp_dir: tmp_dir} do
      start_supervisor(tmp_dir)

      assert {:error, %NotFoundError{resource: :repo}} =
               Mnemosyne.recall_in_context("nonexistent", "session", "query")
    end
  end

  describe "close_and_commit timeout" do
    test "returns {:error, %PipelineError{reason: :extraction_timeout}} when extraction never settles",
         %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      start_supervisor(tmp_dir)
      repo = open_test_repo(tmp_dir)

      {:ok, session_id} = Mnemosyne.start_session("test goal", repo: repo)
      :ok = Mnemosyne.append(session_id, "saw something", "did something")

      stub(Mnemosyne.MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        receive do
          :unblock -> :ok
        end
      end)

      assert {:error, %PipelineError{reason: :extraction_timeout}} =
               Mnemosyne.close_and_commit(session_id,
                 max_retries: 0,
                 max_polls: 3,
                 poll_interval: 10
               )
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
