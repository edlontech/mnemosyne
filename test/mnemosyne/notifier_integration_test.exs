defmodule Mnemosyne.NotifierIntegrationTest do
  use ExUnit.Case, async: true
  use AssertEventually, timeout: 500, interval: 10

  alias Mnemosyne.Config
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Tag
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.GraphBackends.Persistence.DETS
  alias Mnemosyne.MemoryStore
  alias Mnemosyne.NodeMetadata
  alias Mnemosyne.TestNotifier

  @moduletag :tmp_dir

  setup do
    TestNotifier.setup()
    :ok
  end

  defp build_config do
    {:ok, config} =
      Zoi.parse(Config.t(), %{
        llm: %{model: "test-model", opts: %{}},
        embedding: %{model: "test-embed", opts: %{}}
      })

    config
  end

  defp unique_name, do: :"notifier_int_#{System.unique_integer([:positive])}"

  defp unique_repo_id, do: "repo-#{System.unique_integer([:positive])}"

  defp start_store(tmp_dir, opts) do
    dets_path = Path.join(tmp_dir, "test_store_#{System.unique_integer([:positive])}.dets")
    persistence = {DETS, path: dets_path}
    task_sup = :"task_sup_#{System.unique_integer([:positive])}"
    name = Keyword.get_lazy(opts, :name, &unique_name/0)
    start_supervised!({Task.Supervisor, name: task_sup})

    store_opts =
      Keyword.merge(
        [
          name: name,
          backend: {InMemory, persistence: persistence},
          config: build_config(),
          llm: Mnemosyne.MockLLM,
          embedding: Mnemosyne.MockEmbedding,
          task_supervisor: task_sup,
          notifier: TestNotifier
        ],
        opts
      )

    start_supervised!({MemoryStore, store_opts}, id: name)
  end

  defp make_semantic(id, proposition) do
    %Semantic{id: id, proposition: proposition, confidence: 0.9}
  end

  describe "apply_changeset notification" do
    test "emits {:changeset_applied, changeset, metadata} on success", %{tmp_dir: tmp_dir} do
      repo_id = unique_repo_id()
      pid = start_store(tmp_dir, repo_id: repo_id)
      node = make_semantic("s1", "Test fact")
      changeset = Changeset.add_node(Changeset.new(), node)

      :ok = MemoryStore.apply_changeset(pid, changeset)

      assert_eventually(
        Enum.any?(TestNotifier.events(repo_id), fn
          {:changeset_applied, %Changeset{}, %{}} -> true
          _ -> false
        end)
      )
    end
  end

  describe "delete_nodes notification" do
    test "emits {:nodes_deleted, node_ids, metadata} on success", %{tmp_dir: tmp_dir} do
      repo_id = unique_repo_id()
      pid = start_store(tmp_dir, repo_id: repo_id)
      node = make_semantic("del-1", "To delete")
      changeset = Changeset.add_node(Changeset.new(), node)
      :ok = MemoryStore.apply_changeset(pid, changeset)

      assert_eventually(
        Enum.any?(TestNotifier.events(repo_id), &match?({:changeset_applied, _, %{}}, &1))
      )

      :ok = MemoryStore.delete_nodes(pid, ["del-1"])

      assert_eventually(
        Enum.any?(TestNotifier.events(repo_id), &match?({:nodes_deleted, ["del-1"], %{}}, &1))
      )
    end
  end

  describe "consolidate_semantics notification" do
    test "emits {:consolidation_completed, stats, metadata} on success", %{tmp_dir: tmp_dir} do
      repo_id = unique_repo_id()
      pid = start_store(tmp_dir, repo_id: repo_id)

      emb = List.duplicate(0.5, 128)
      emb_similar = List.duplicate(0.5, 127) ++ [0.50001]

      tag = %Tag{id: "t1", label: "elixir", links: MapSet.new(["s1", "s2"])}

      sem1 = %Semantic{
        id: "s1",
        proposition: "Elixir is great",
        confidence: 0.9,
        embedding: emb,
        links: MapSet.new(["t1"])
      }

      sem2 = %Semantic{
        id: "s2",
        proposition: "Elixir is awesome",
        confidence: 0.9,
        embedding: emb_similar,
        links: MapSet.new(["t1"])
      }

      meta1 = NodeMetadata.new(created_at: DateTime.utc_now(), access_count: 5)
      meta2 = NodeMetadata.new(created_at: DateTime.utc_now(), access_count: 0)

      changeset =
        Changeset.new()
        |> Changeset.add_node(tag)
        |> Changeset.add_node(sem1)
        |> Changeset.add_node(sem2)
        |> Changeset.put_metadata("s1", meta1)
        |> Changeset.put_metadata("s2", meta2)

      :ok = MemoryStore.apply_changeset(pid, changeset)

      assert_eventually(
        Enum.any?(TestNotifier.events(repo_id), &match?({:changeset_applied, _, %{}}, &1))
      )

      :ok = MemoryStore.consolidate_semantics(pid)

      assert_eventually(
        Enum.any?(TestNotifier.events(repo_id), fn
          {:consolidation_completed, %{checked: _, deleted: _, deleted_ids: _}, %{}} -> true
          _ -> false
        end)
      )
    end
  end

  describe "decay_nodes notification" do
    test "emits {:decay_completed, stats, metadata} on success", %{tmp_dir: tmp_dir} do
      repo_id = unique_repo_id()
      pid = start_store(tmp_dir, repo_id: repo_id)

      old_time = ~U[2020-01-01 00:00:00Z]
      emb = List.duplicate(0.5, 128)

      sem = %Semantic{id: "s-old", proposition: "Stale fact", confidence: 0.9, embedding: emb}
      meta = NodeMetadata.new(created_at: old_time, access_count: 0)

      changeset =
        Changeset.new()
        |> Changeset.add_node(sem)
        |> Changeset.put_metadata("s-old", meta)

      :ok = MemoryStore.apply_changeset(pid, changeset)

      assert_eventually(
        Enum.any?(TestNotifier.events(repo_id), &match?({:changeset_applied, _, %{}}, &1))
      )

      :ok = MemoryStore.decay_nodes(pid)

      assert_eventually(
        Enum.any?(TestNotifier.events(repo_id), fn
          {:decay_completed, %{checked: _, deleted: _, deleted_ids: _}, %{}} -> true
          _ -> false
        end)
      )
    end
  end
end

defmodule Mnemosyne.NotifierSessionIntegrationTest do
  use ExUnit.Case, async: false
  use AssertEventually, timeout: 500, interval: 10

  import Mimic

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.GraphBackends.Persistence.DETS
  alias Mnemosyne.LLM
  alias Mnemosyne.MemoryStore
  alias Mnemosyne.Session
  alias Mnemosyne.TestNotifier

  @moduletag :tmp_dir

  setup :set_mimic_global

  setup do
    TestNotifier.setup()
    :ok
  end

  defp build_config do
    {:ok, config} =
      Zoi.parse(Config.t(), %{
        llm: %{model: "test-model", opts: %{}},
        embedding: %{model: "test-embed", opts: %{}},
        session: %{auto_commit: false, flush_timeout_ms: :infinity, session_timeout_ms: :infinity}
      })

    config
  end

  defp start_infra(tmp_dir) do
    registry = :"registry_#{System.unique_integer([:positive])}"
    task_sup = :"task_sup_#{System.unique_integer([:positive])}"
    store_name = :"store_#{System.unique_integer([:positive])}"
    dets_path = Path.join(tmp_dir, "session_notifier_test.dets")
    repo_id = "repo-#{System.unique_integer([:positive])}"

    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Task.Supervisor, name: task_sup})

    persistence = {DETS, path: dets_path}

    store_opts = [
      name: store_name,
      repo_id: repo_id,
      backend: {InMemory, persistence: persistence},
      config: build_config(),
      llm: Mnemosyne.MockLLM,
      embedding: Mnemosyne.MockEmbedding,
      task_supervisor: task_sup,
      notifier: TestNotifier
    ]

    start_supervised!({MemoryStore, store_opts}, id: store_name)

    %{
      registry: registry,
      task_supervisor: task_sup,
      memory_store: store_name,
      config: build_config(),
      repo_id: repo_id
    }
  end

  defp start_session(infra) do
    session_opts = [
      registry: infra.registry,
      task_supervisor: infra.task_supervisor,
      memory_store: infra.memory_store,
      config: infra.config,
      repo_id: infra.repo_id,
      llm: Mnemosyne.MockLLM,
      embedding: Mnemosyne.MockEmbedding,
      notifier: TestNotifier
    ]

    start_supervised!({Session, session_opts},
      id: :"session_#{System.unique_integer([:positive])}"
    )
  end

  defp stub_llm_for_episode do
    stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
      {:ok, %LLM.Response{content: "0.5", model: "test", usage: %{}}}
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

  describe "session transition notifications" do
    test "emits idle->collecting on start_episode", %{tmp_dir: tmp_dir} do
      infra = start_infra(tmp_dir)
      pid = start_session(infra)
      session_id = Session.id(pid)

      :ok = Session.start_episode(pid, "test goal")

      events = TestNotifier.events(infra.repo_id)

      assert Enum.any?(events, fn
               {:session_transition, ^session_id, :idle, :collecting, %{}} -> true
               _ -> false
             end)
    end

    test "emits collecting->extracting->ready on successful extraction", %{tmp_dir: tmp_dir} do
      stub_extraction_success()
      infra = start_infra(tmp_dir)
      pid = start_session(infra)
      session_id = Session.id(pid)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "saw something", "did something")
      :ok = Session.close(pid)

      Process.sleep(300)
      assert Session.state(pid) == :ready

      events = TestNotifier.events(infra.repo_id)

      assert Enum.any?(events, fn
               {:session_transition, ^session_id, :collecting, :extracting, %{}} -> true
               _ -> false
             end)

      assert Enum.any?(events, fn
               {:session_transition, ^session_id, :extracting, :ready, %{}} -> true
               _ -> false
             end)
    end

    test "emits ready->idle on commit with node_ids", %{tmp_dir: tmp_dir} do
      stub_extraction_success()
      infra = start_infra(tmp_dir)
      pid = start_session(infra)
      session_id = Session.id(pid)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "saw something", "did something")
      :ok = Session.close(pid)

      Process.sleep(300)
      assert Session.state(pid) == :ready

      :ok = Session.commit(pid)

      events = TestNotifier.events(infra.repo_id)

      assert Enum.any?(events, fn
               {:session_transition, ^session_id, :ready, :idle, %{node_ids: node_ids}}
               when is_list(node_ids) and node_ids != [] ->
                 true

               _ ->
                 false
             end)
    end

    test "trajectory_committed event includes node_ids on boundary detection", %{
      tmp_dir: tmp_dir
    } do
      call_count = :counters.new(1, [:atomics])

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
            String.contains?(system_content, "factual knowledge") ->
              %{facts: [%{proposition: "some fact", concepts: ["concept1"]}]}

            String.contains?(system_content, "actionable instructions") ->
              %{
                instructions: [
                  %{
                    intent: "goal",
                    condition: "cond",
                    instruction: "act",
                    expected_outcome: "out"
                  }
                ]
              }

            true ->
              %{}
          end

        {:ok, %LLM.Response{content: content, model: "test", usage: %{}}}
      end)

      stub(Mnemosyne.MockEmbedding, :embed, fn _text, _opts ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        vec =
          if count == 1 do
            List.duplicate(0.9, 128)
          else
            List.duplicate(-0.9, 128)
          end

        {:ok, %Embedding.Response{vectors: [vec], model: "test", usage: %{}}}
      end)

      stub(Mnemosyne.MockEmbedding, :embed_batch, fn texts, _opts ->
        vectors = Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)
        {:ok, %Embedding.Response{vectors: vectors, model: "test", usage: %{}}}
      end)

      {:ok, auto_config} =
        Zoi.parse(Config.t(), %{
          llm: %{model: "test-model", opts: %{}},
          embedding: %{model: "test-embed", opts: %{}},
          session: %{
            auto_commit: true,
            flush_timeout_ms: :infinity,
            session_timeout_ms: :infinity
          }
        })

      infra = start_infra(tmp_dir)

      session_opts = [
        registry: infra.registry,
        task_supervisor: infra.task_supervisor,
        memory_store: infra.memory_store,
        config: auto_config,
        repo_id: infra.repo_id,
        llm: Mnemosyne.MockLLM,
        embedding: Mnemosyne.MockEmbedding,
        notifier: TestNotifier
      ]

      pid =
        start_supervised!({Session, session_opts},
          id: :"session_boundary_#{System.unique_integer([:positive])}"
        )

      session_id = Session.id(pid)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "obs1", "act1")
      :ok = Session.append(pid, "obs2", "act2")

      assert_eventually(
        Enum.any?(TestNotifier.events(infra.repo_id), fn
          {:trajectory_committed, ^session_id, _traj_id, %{node_count: count, node_ids: node_ids},
           %{trace: _}}
          when is_list(node_ids) and count == length(node_ids) and node_ids != [] ->
            Enum.all?(node_ids, &is_binary/1)

          _ ->
            false
        end)
      )
    end

    test "emits extracting->idle with node_ids on auto-commit", %{tmp_dir: tmp_dir} do
      stub_extraction_success()
      infra = start_infra(tmp_dir)

      {:ok, auto_config} =
        Zoi.parse(Config.t(), %{
          llm: %{model: "test-model", opts: %{}},
          embedding: %{model: "test-embed", opts: %{}},
          session: %{
            auto_commit: true,
            flush_timeout_ms: :infinity,
            session_timeout_ms: :infinity
          }
        })

      session_opts = [
        registry: infra.registry,
        task_supervisor: infra.task_supervisor,
        memory_store: infra.memory_store,
        config: auto_config,
        repo_id: infra.repo_id,
        llm: Mnemosyne.MockLLM,
        embedding: Mnemosyne.MockEmbedding,
        notifier: TestNotifier
      ]

      pid =
        start_supervised!({Session, session_opts},
          id: :"session_auto_#{System.unique_integer([:positive])}"
        )

      session_id = Session.id(pid)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "saw something", "did something")
      :ok = Session.close(pid)

      Process.sleep(300)
      assert Session.state(pid) == :idle

      events = TestNotifier.events(infra.repo_id)

      assert Enum.any?(events, fn
               {:session_transition, ^session_id, :extracting, :idle, %{node_ids: node_ids}}
               when is_list(node_ids) and node_ids != [] ->
                 true

               _ ->
                 false
             end)
    end

    test "emits extracting->failed on extraction error", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      infra = start_infra(tmp_dir)
      pid = start_session(infra)
      session_id = Session.id(pid)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "saw something", "did something")

      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        {:error, :extraction_failed}
      end)

      stub(Mnemosyne.MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        {:error, :extraction_failed}
      end)

      :ok = Session.close(pid)

      Process.sleep(300)
      assert Session.state(pid) == :failed

      events = TestNotifier.events(infra.repo_id)

      assert Enum.any?(events, fn
               {:session_transition, ^session_id, :extracting, :failed, %{}} -> true
               _ -> false
             end)
    end

    test "emits failed->idle on discard", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      infra = start_infra(tmp_dir)
      pid = start_session(infra)
      session_id = Session.id(pid)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "saw something", "did something")

      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        {:error, :extraction_failed}
      end)

      :ok = Session.close(pid)

      Process.sleep(300)
      assert Session.state(pid) == :failed

      :ok = Session.discard(pid)

      events = TestNotifier.events(infra.repo_id)

      assert Enum.any?(events, fn
               {:session_transition, ^session_id, :failed, :idle, %{}} -> true
               _ -> false
             end)
    end

    test "emits ready->idle on discard", %{tmp_dir: tmp_dir} do
      stub_extraction_success()
      infra = start_infra(tmp_dir)
      pid = start_session(infra)
      session_id = Session.id(pid)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "saw something", "did something")
      :ok = Session.close(pid)

      Process.sleep(300)
      assert Session.state(pid) == :ready

      :ok = Session.discard(pid)

      events = TestNotifier.events(infra.repo_id)

      assert Enum.any?(events, fn
               {:session_transition, ^session_id, :ready, :idle, %{}} -> true
               _ -> false
             end)
    end

    test "emits step_appended on append with trace", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      infra = start_infra(tmp_dir)
      pid = start_session(infra)
      session_id = Session.id(pid)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "saw something", "did something")

      assert_eventually(
        Enum.any?(TestNotifier.events(infra.repo_id), fn
          {:step_appended, ^session_id,
           %{step_index: 0, trajectory_id: _, boundary_detected: false},
           %{trace: %Mnemosyne.Notifier.Trace.Episode{}}} ->
            true

          _ ->
            false
        end)
      )
    end

    test "emits failed->extracting on retry via commit", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      infra = start_infra(tmp_dir)
      pid = start_session(infra)
      session_id = Session.id(pid)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "saw something", "did something")

      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        {:error, :extraction_failed}
      end)

      stub(Mnemosyne.MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        {:error, :extraction_failed}
      end)

      :ok = Session.close(pid)

      Process.sleep(300)
      assert Session.state(pid) == :failed

      stub_extraction_success()
      :ok = Session.commit(pid)

      events = TestNotifier.events(infra.repo_id)

      assert Enum.any?(events, fn
               {:session_transition, ^session_id, :failed, :extracting, %{}} -> true
               _ -> false
             end)
    end
  end
end

defmodule Mnemosyne.NotifierRecallIntegrationTest do
  use ExUnit.Case, async: false
  use AssertEventually, timeout: 500, interval: 10

  import Mimic

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Tag
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.GraphBackends.Persistence.DETS
  alias Mnemosyne.LLM
  alias Mnemosyne.MemoryStore
  alias Mnemosyne.TestNotifier

  @moduletag :tmp_dir

  setup :set_mimic_global

  setup do
    TestNotifier.setup()
    :ok
  end

  defp build_config do
    {:ok, config} =
      Zoi.parse(Config.t(), %{
        llm: %{model: "test-model", opts: %{}},
        embedding: %{model: "test-embed", opts: %{}}
      })

    config
  end

  defp unique_name, do: :"notifier_recall_#{System.unique_integer([:positive])}"

  defp unique_repo_id, do: "repo-#{System.unique_integer([:positive])}"

  defp start_store(tmp_dir, opts) do
    dets_path = Path.join(tmp_dir, "test_store_#{System.unique_integer([:positive])}.dets")
    persistence = {DETS, path: dets_path}
    task_sup = :"task_sup_#{System.unique_integer([:positive])}"
    name = Keyword.get_lazy(opts, :name, &unique_name/0)
    start_supervised!({Task.Supervisor, name: task_sup})

    store_opts =
      Keyword.merge(
        [
          name: name,
          backend: {InMemory, persistence: persistence},
          config: build_config(),
          llm: Mnemosyne.MockLLM,
          embedding: Mnemosyne.MockEmbedding,
          task_supervisor: task_sup,
          notifier: TestNotifier
        ],
        opts
      )

    start_supervised!({MemoryStore, store_opts}, id: name)
  end

  describe "recall notification" do
    test "emits {:recall_executed, query, result, metadata} on success", %{tmp_dir: tmp_dir} do
      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        {:ok, %LLM.Response{content: "semantic", model: "test", usage: %{}}}
      end)

      stub(Mnemosyne.MockEmbedding, :embed, fn _text, _opts ->
        {:ok, %Embedding.Response{vectors: [List.duplicate(0.1, 128)], model: "test", usage: %{}}}
      end)

      stub(Mnemosyne.MockEmbedding, :embed_batch, fn texts, _opts ->
        vectors = Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)
        {:ok, %Embedding.Response{vectors: vectors, model: "test", usage: %{}}}
      end)

      repo_id = unique_repo_id()
      pid = start_store(tmp_dir, repo_id: repo_id)

      node = %Semantic{id: "s1", proposition: "Elixir is functional", confidence: 0.9}
      tag = %Tag{id: "t1", label: "elixir"}

      changeset =
        Changeset.new()
        |> Changeset.add_node(node)
        |> Changeset.add_node(tag)

      :ok = MemoryStore.apply_changeset(pid, changeset)

      assert_eventually(
        Enum.any?(TestNotifier.events(repo_id), &match?({:changeset_applied, _, %{}}, &1))
      )

      {:ok, _} = MemoryStore.recall(pid, "what is elixir?")

      events = TestNotifier.events(repo_id)

      assert Enum.any?(events, fn
               {:recall_executed, "what is elixir?", {:ok, _},
                %{trace: %Mnemosyne.Notifier.Trace.Recall{}}} ->
                 true

               _ ->
                 false
             end)
    end

    test "emits {:recall_failed, query, reason, metadata} on failure", %{tmp_dir: tmp_dir} do
      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        {:error, :llm_unavailable}
      end)

      stub(Mnemosyne.MockEmbedding, :embed, fn _text, _opts ->
        {:error, :embed_unavailable}
      end)

      stub(Mnemosyne.MockEmbedding, :embed_batch, fn _texts, _opts ->
        {:error, :embed_unavailable}
      end)

      repo_id = unique_repo_id()
      pid = start_store(tmp_dir, repo_id: repo_id)

      {:error, _} = MemoryStore.recall(pid, "failing query")

      events = TestNotifier.events(repo_id)

      assert Enum.any?(events, fn
               {:recall_failed, "failing query", _reason, %{}} -> true
               _ -> false
             end)
    end
  end
end
