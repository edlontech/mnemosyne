defmodule Mnemosyne.SessionTest do
  use ExUnit.Case, async: false
  use AssertEventually, timeout: 1000, interval: 25

  import Mimic

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.Errors.Framework.SessionError
  alias Mnemosyne.GraphBackends.Persistence.DETS, as: PersistenceDETS
  alias Mnemosyne.LLM
  alias Mnemosyne.MemoryStore
  alias Mnemosyne.Session

  @moduletag :tmp_dir

  setup :set_mimic_global

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
    dets_path = Path.join(tmp_dir, "session_test.dets")

    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Task.Supervisor, name: task_sup})

    persistence = {PersistenceDETS, path: dets_path}

    store_opts = [
      name: store_name,
      backend: {Mnemosyne.GraphBackends.InMemory, persistence: persistence},
      config: build_config(),
      llm: Mnemosyne.MockLLM,
      embedding: Mnemosyne.MockEmbedding,
      task_supervisor: task_sup
    ]

    start_supervised!({MemoryStore, store_opts}, id: store_name)

    %{
      registry: registry,
      task_supervisor: task_sup,
      memory_store: store_name,
      config: build_config()
    }
  end

  defp start_session(infra, opts \\ []) do
    session_opts =
      Keyword.merge(
        [
          registry: infra.registry,
          task_supervisor: infra.task_supervisor,
          memory_store: infra.memory_store,
          config: infra.config,
          llm: Mnemosyne.MockLLM,
          embedding: Mnemosyne.MockEmbedding
        ],
        opts
      )

    start_supervised!({Session, session_opts},
      id: :"session_#{System.unique_integer([:positive])}"
    )
  end

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
            %{scores: [%{index: 0, return_score: 0.85}]}

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

  describe "start_link/1" do
    test "starts in idle state", %{tmp_dir: tmp_dir} do
      infra = start_infra(tmp_dir)
      pid = start_session(infra)
      assert Session.state(pid) == :idle
    end

    test "registers via Registry with generated ID", %{tmp_dir: tmp_dir} do
      infra = start_infra(tmp_dir)
      pid = start_session(infra)
      id = Session.id(pid)
      assert [{^pid, nil}] = Registry.lookup(infra.registry, id)
    end
  end

  describe "start_episode/2" do
    test "transitions from idle to collecting", %{tmp_dir: tmp_dir} do
      infra = start_infra(tmp_dir)
      pid = start_session(infra)

      assert :ok = Session.start_episode(pid, "test goal")
      assert Session.state(pid) == :collecting
    end

    test "rejects start_episode when not idle", %{tmp_dir: tmp_dir} do
      infra = start_infra(tmp_dir)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "goal")

      assert {:error, %SessionError{reason: :not_idle}} =
               Session.start_episode(pid, "another goal")
    end
  end

  describe "append/3" do
    test "adds step in collecting state", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      infra = start_infra(tmp_dir)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      assert :ok = Session.append(pid, "saw something", "did something")
      assert Session.state(pid) == :collecting
    end

    test "rejects append when not collecting", %{tmp_dir: tmp_dir} do
      infra = start_infra(tmp_dir)
      pid = start_session(infra)

      assert {:error, %SessionError{reason: :not_collecting}} = Session.append(pid, "obs", "act")
    end

    test "returns error when LLM fails", %{tmp_dir: tmp_dir} do
      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        {:error, :llm_failure}
      end)

      infra = start_infra(tmp_dir)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      assert {:error, :llm_failure} = Session.append(pid, "obs", "act")
      assert Session.state(pid) == :collecting
    end
  end

  describe "close/1 and extraction" do
    test "transitions to extracting then ready on success", %{tmp_dir: tmp_dir} do
      stub_extraction_success()
      infra = start_infra(tmp_dir)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "saw something", "did something")
      assert :ok = Session.close(pid)
      assert Session.state(pid) == :extracting

      assert_eventually(Session.state(pid) == :ready)
    end

    test "transitions to failed on extraction error", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      infra = start_infra(tmp_dir)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "saw something", "did something")

      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        {:error, :extraction_failed}
      end)

      stub(Mnemosyne.MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        {:error, :extraction_failed}
      end)

      assert :ok = Session.close(pid)

      assert_eventually(Session.state(pid) == :failed)
    end

    test "rejects operations during extracting", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      infra = start_infra(tmp_dir)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "saw something", "did something")

      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        Process.sleep(500)
        {:ok, %LLM.Response{content: "test", model: "test", usage: %{}}}
      end)

      stub(Mnemosyne.MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        Process.sleep(500)
        {:ok, %LLM.Response{content: %{}, model: "test", usage: %{}}}
      end)

      :ok = Session.close(pid)

      assert {:error, %SessionError{reason: :extraction_in_progress}} =
               Session.append(pid, "obs", "act")

      assert {:error, %SessionError{reason: :extraction_in_progress}} = Session.close(pid)
    end
  end

  describe "commit/1" do
    test "in ready state: applies changeset to MemoryStore and goes idle", %{tmp_dir: tmp_dir} do
      stub_extraction_success()
      infra = start_infra(tmp_dir)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "saw something", "did something")
      :ok = Session.close(pid)

      assert_eventually(Session.state(pid) == :ready)

      assert :ok = Session.commit(pid)
      assert Session.state(pid) == :idle
    end

    test "in failed state: retries extraction", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      infra = start_infra(tmp_dir)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "saw something", "did something")

      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        {:error, :extraction_failed}
      end)

      stub(Mnemosyne.MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        {:error, :extraction_failed}
      end)

      :ok = Session.close(pid)
      assert_eventually(Session.state(pid) == :failed)

      stub_extraction_success()
      assert :ok = Session.commit(pid)
      assert Session.state(pid) == :extracting

      assert_eventually(Session.state(pid) == :ready)
    end

    test "rejects commit when idle", %{tmp_dir: tmp_dir} do
      infra = start_infra(tmp_dir)
      pid = start_session(infra)

      assert {:error, _} = Session.commit(pid)
    end
  end

  describe "discard/1" do
    test "from ready goes to idle", %{tmp_dir: tmp_dir} do
      stub_extraction_success()
      infra = start_infra(tmp_dir)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "saw something", "did something")
      :ok = Session.close(pid)

      assert_eventually(Session.state(pid) == :ready)

      assert :ok = Session.discard(pid)
      assert Session.state(pid) == :idle
    end

    test "from failed goes to idle", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      infra = start_infra(tmp_dir)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "saw something", "did something")

      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        {:error, :extraction_failed}
      end)

      :ok = Session.close(pid)
      assert_eventually(Session.state(pid) == :failed)

      assert :ok = Session.discard(pid)
      assert Session.state(pid) == :idle
    end

    test "rejects discard when collecting", %{tmp_dir: tmp_dir} do
      infra = start_infra(tmp_dir)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      assert {:error, _} = Session.discard(pid)
    end
  end

  describe "get_context/1" do
    test "returns nil when idle", %{tmp_dir: tmp_dir} do
      infra = start_infra(tmp_dir)
      pid = start_session(infra)

      assert {:ok, nil} = Session.get_context(pid)
    end

    test "returns episode data when collecting", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      infra = start_infra(tmp_dir)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "saw something", "did something")

      assert {:ok, %{goal: "test goal", recent_steps: steps}} = Session.get_context(pid)
      assert length(steps) == 1
    end

    test "returns episode data when extracting", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      infra = start_infra(tmp_dir)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "saw something", "did something")

      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        Process.sleep(500)
        {:ok, %LLM.Response{content: "test", model: "test", usage: %{}}}
      end)

      stub(Mnemosyne.MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        Process.sleep(500)
        {:ok, %LLM.Response{content: %{}, model: "test", usage: %{}}}
      end)

      :ok = Session.close(pid)

      assert {:ok, %{goal: "test goal", recent_steps: _}} = Session.get_context(pid)
    end
  end

  describe "get_context/2 with string ID and registry" do
    test "looks up session by string ID in the given registry", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      infra = start_infra(tmp_dir)
      pid = start_session(infra)
      id = Session.id(pid)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "saw something", "did something")

      assert {:ok, %{goal: "test goal", recent_steps: steps}} =
               Session.get_context(id, infra.registry)

      assert length(steps) == 1
    end

    test "returns nil for unknown session ID", %{tmp_dir: tmp_dir} do
      infra = start_infra(tmp_dir)

      assert {:ok, nil} = Session.get_context("nonexistent", infra.registry)
    end

    test "returns nil when registry does not exist" do
      assert {:ok, nil} = Session.get_context("anything", :nonexistent_registry)
    end
  end

  defp build_config_with_timeouts(auto_commit, flush_ms, session_ms) do
    {:ok, config} =
      Zoi.parse(Config.t(), %{
        llm: %{model: "test-model", opts: %{}},
        embedding: %{model: "test-embed", opts: %{}},
        session: %{
          auto_commit: auto_commit,
          flush_timeout_ms: flush_ms,
          session_timeout_ms: session_ms
        }
      })

    config
  end

  defp start_infra_with_auto_commit(tmp_dir, auto_commit) do
    start_infra_with_timeouts(tmp_dir, auto_commit)
  end

  defp start_infra_with_timeouts(
         tmp_dir,
         auto_commit,
         flush_ms \\ :infinity,
         session_ms \\ :infinity
       ) do
    config = build_config_with_timeouts(auto_commit, flush_ms, session_ms)
    registry = :"registry_#{System.unique_integer([:positive])}"
    task_sup = :"task_sup_#{System.unique_integer([:positive])}"
    store_name = :"store_#{System.unique_integer([:positive])}"
    dets_path = Path.join(tmp_dir, "session_test_timeout.dets")

    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Task.Supervisor, name: task_sup})

    persistence = {PersistenceDETS, path: dets_path}

    store_opts = [
      name: store_name,
      backend: {Mnemosyne.GraphBackends.InMemory, persistence: persistence},
      config: config,
      llm: Mnemosyne.MockLLM,
      embedding: Mnemosyne.MockEmbedding,
      task_supervisor: task_sup
    ]

    start_supervised!({MemoryStore, store_opts}, id: store_name)

    %{
      registry: registry,
      task_supervisor: task_sup,
      memory_store: store_name,
      config: config
    }
  end

  defp stub_llm_for_episode_with_boundary do
    call_count = :counters.new(1, [:atomics])

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
      count = :counters.get(call_count, 1)
      :counters.add(call_count, 1, 1)
      embedding = boundary_embedding(count)
      {:ok, %Embedding.Response{vectors: [embedding], model: "test", usage: %{}}}
    end)
  end

  defp boundary_embedding(count) when count < 1, do: List.duplicate(0.1, 128)

  defp boundary_embedding(_count) do
    for i <- 1..128, do: if(rem(i, 2) == 0, do: 0.9, else: -0.9)
  end

  defp alternating_embedding(count) when rem(count, 2) == 0, do: List.duplicate(0.1, 128)

  defp alternating_embedding(_count) do
    for i <- 1..128, do: if(rem(i, 2) == 0, do: 0.9, else: -0.9)
  end

  defp stub_trajectory_extraction_success do
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
            %{scores: [%{index: 0, return_score: 0.85}]}

          true ->
            %{}
        end

      {:ok, %LLM.Response{content: content, model: "test", usage: %{}}}
    end)

    stub(Mnemosyne.MockEmbedding, :embed_batch, fn texts, _opts ->
      vectors = Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)
      {:ok, %Embedding.Response{vectors: vectors, model: "test", usage: %{}}}
    end)
  end

  describe "auto-commit on trajectory boundary" do
    test "triggers background extraction and commits to MemoryStore", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode_with_boundary()
      stub_trajectory_extraction_success()

      infra = start_infra_with_auto_commit(tmp_dir, true)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "first obs", "first act")
      :ok = Session.append(pid, "second obs", "second act")

      assert_eventually(map_size(MemoryStore.get_graph(infra.memory_store).nodes) > 0)
      assert Session.state(pid) == :collecting
    end

    test "does NOT trigger extraction without trajectory boundary", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()

      infra = start_infra_with_auto_commit(tmp_dir, true)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "first obs", "first act")
      :ok = Session.append(pid, "second obs", "second act")

      assert_eventually(Session.state(pid) == :collecting)
      assert map_size(MemoryStore.get_graph(infra.memory_store).nodes) == 0
    end

    test "auto_commit: false preserves manual mode behavior", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode_with_boundary()

      infra = start_infra_with_auto_commit(tmp_dir, false)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "first obs", "first act")
      :ok = Session.append(pid, "second obs", "second act")

      assert_eventually(Session.state(pid) == :collecting)
      assert map_size(MemoryStore.get_graph(infra.memory_store).nodes) == 0
    end

    test "failed trajectory extraction keeps session in :collecting", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode_with_boundary()

      stub(Mnemosyne.MockLLM, :chat_structured, fn messages, _schema, _opts ->
        system_content =
          messages
          |> Enum.find(%{content: ""}, &(&1.role == :system))
          |> Map.get(:content, "")

        if String.contains?(system_content, "subgoal") do
          {:ok,
           %LLM.Response{
             content: %{"reasoning" => "analysis", "subgoal" => "test subgoal"},
             model: "test",
             usage: %{}
           }}
        else
          {:error, :extraction_failed}
        end
      end)

      infra = start_infra_with_auto_commit(tmp_dir, true)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "first obs", "first act")
      :ok = Session.append(pid, "second obs", "second act")

      assert_eventually(Session.state(pid) == :collecting)
    end

    test "trajectory extraction crash keeps session in :collecting", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode_with_boundary()

      stub(Mnemosyne.MockLLM, :chat_structured, fn messages, _schema, _opts ->
        system_content =
          messages
          |> Enum.find(%{content: ""}, &(&1.role == :system))
          |> Map.get(:content, "")

        if String.contains?(system_content, "subgoal") do
          {:ok,
           %LLM.Response{
             content: %{"reasoning" => "analysis", "subgoal" => "test subgoal"},
             model: "test",
             usage: %{}
           }}
        else
          raise "crash during extraction"
        end
      end)

      infra = start_infra_with_auto_commit(tmp_dir, true)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "first obs", "first act")
      :ok = Session.append(pid, "second obs", "second act")

      assert_eventually(Session.state(pid) == :collecting)
    end

    test "stopping flag with failed extraction terminates session", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()

      stub(Mnemosyne.MockLLM, :chat_structured, fn messages, _schema, _opts ->
        system_content =
          messages
          |> Enum.find(%{content: ""}, &(&1.role == :system))
          |> Map.get(:content, "")

        if String.contains?(system_content, "subgoal") do
          {:ok,
           %LLM.Response{
             content: %{"reasoning" => "analysis", "subgoal" => "test subgoal"},
             model: "test",
             usage: %{}
           }}
        else
          {:error, :extraction_failed}
        end
      end)

      infra = start_infra_with_timeouts(tmp_dir, true, 50, 100)
      pid = start_session(infra)
      mon_ref = Process.monitor(pid)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "saw something", "did something")

      assert_receive {:DOWN, ^mon_ref, :process, ^pid, :normal}, 2_000
    end
  end

  describe "close/1 with auto-commit" do
    test "rejects close when trajectory extraction is in-flight", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode_with_boundary()

      stub(Mnemosyne.MockLLM, :chat_structured, fn messages, _schema, _opts ->
        system_content =
          messages
          |> Enum.find(%{content: ""}, &(&1.role == :system))
          |> Map.get(:content, "")

        if String.contains?(system_content, "subgoal") do
          {:ok,
           %LLM.Response{
             content: %{"reasoning" => "analysis", "subgoal" => "test subgoal"},
             model: "test",
             usage: %{}
           }}
        else
          Process.sleep(500)
          {:ok, %LLM.Response{content: %{facts: []}, model: "test", usage: %{}}}
        end
      end)

      stub(Mnemosyne.MockEmbedding, :embed_batch, fn texts, _opts ->
        vectors = Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)
        {:ok, %Embedding.Response{vectors: vectors, model: "test", usage: %{}}}
      end)

      infra = start_infra_with_auto_commit(tmp_dir, true)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "first obs", "first act")
      :ok = Session.append(pid, "second obs", "second act")

      Process.sleep(50)

      assert {:error, %SessionError{reason: :extraction_in_progress}} = Session.close(pid)
    end

    test "goes straight to idle when everything already committed", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode_with_boundary()
      stub_trajectory_extraction_success()

      infra = start_infra_with_auto_commit(tmp_dir, true)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "first obs", "first act")
      :ok = Session.append(pid, "second obs", "second act")

      # Wait for auto-commit of first trajectory
      assert_eventually(map_size(MemoryStore.get_graph(infra.memory_store).nodes) > 0)

      assert :ok = Session.close(pid)

      assert_eventually(Session.state(pid) == :idle)
    end

    test "extracts only uncommitted trajectory on close", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode_with_boundary()
      stub_trajectory_extraction_success()

      infra = start_infra_with_auto_commit(tmp_dir, true)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "first obs", "first act")
      :ok = Session.append(pid, "second obs", "second act")

      # Wait for auto-commit
      assert_eventually(map_size(MemoryStore.get_graph(infra.memory_store).nodes) > 0)

      assert :ok = Session.close(pid)

      assert_eventually(Session.state(pid) == :idle)
    end
  end

  describe "flush timeout" do
    test "extracts current trajectory after idle period", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      stub_trajectory_extraction_success()

      infra = start_infra_with_timeouts(tmp_dir, true, 50, :infinity)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "obs1", "act1")

      assert_eventually(map_size(MemoryStore.get_graph(infra.memory_store).nodes) > 0)
      assert Session.state(pid) == :collecting
    end

    test "reschedules when append is in progress", %{tmp_dir: tmp_dir} do
      slow_append = :counters.new(1, [:atomics])

      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        if :counters.get(slow_append, 1) > 0 do
          Process.sleep(200)
        end

        {:ok, %LLM.Response{content: "0.5", model: "test", usage: %{}}}
      end)

      stub(Mnemosyne.MockEmbedding, :embed, fn _text, _opts ->
        {:ok, %Embedding.Response{vectors: [List.duplicate(0.1, 128)], model: "test", usage: %{}}}
      end)

      stub_trajectory_extraction_success()

      infra = start_infra_with_timeouts(tmp_dir, true, 50, :infinity)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "obs1", "act1")

      :counters.add(slow_append, 1, 1)
      Session.append_async(pid, "obs2", "act2")
      Process.sleep(80)

      assert Session.state(pid) == :collecting
      assert map_size(MemoryStore.get_graph(infra.memory_store).nodes) == 0
    end

    test "does not fire with :infinity timeout", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()

      infra = start_infra_with_timeouts(tmp_dir, true, :infinity, :infinity)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "obs1", "act1")

      Process.sleep(100)

      assert Session.state(pid) == :collecting
      assert map_size(MemoryStore.get_graph(infra.memory_store).nodes) == 0
    end

    test "commits steps appended after a previous flush on same trajectory", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      stub_trajectory_extraction_success()

      infra = start_infra_with_timeouts(tmp_dir, true, 50, :infinity)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "obs1", "act1")

      assert_eventually(map_size(MemoryStore.get_graph(infra.memory_store).nodes) > 0)

      initial_count = map_size(MemoryStore.get_graph(infra.memory_store).nodes)

      :ok = Session.append(pid, "obs2", "act2")
      :ok = Session.append(pid, "obs3", "act3")

      assert_eventually(map_size(MemoryStore.get_graph(infra.memory_store).nodes) > initial_count)
      assert Session.state(pid) == :collecting
    end
  end

  describe "session timeout" do
    test "terminates process after longer idle", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      stub_trajectory_extraction_success()

      infra = start_infra_with_timeouts(tmp_dir, true, 50, 150)
      pid = start_session(infra)
      monitor_ref = Process.monitor(pid)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "obs1", "act1")

      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}, 1000
    end

    test "waits for in-flight extraction before stopping", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()

      stub(Mnemosyne.MockLLM, :chat_structured, fn messages, _schema, _opts ->
        system_content =
          messages
          |> Enum.find(%{content: ""}, &(&1.role == :system))
          |> Map.get(:content, "")

        if String.contains?(system_content, "subgoal") do
          {:ok,
           %LLM.Response{
             content: %{"reasoning" => "analysis", "subgoal" => "test subgoal"},
             model: "test",
             usage: %{}
           }}
        else
          Process.sleep(200)

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

              String.contains?(system_content, "prescription quality") ->
                %{scores: [%{index: 0, return_score: 0.85}]}

              true ->
                %{}
            end

          {:ok, %LLM.Response{content: content, model: "test", usage: %{}}}
        end
      end)

      stub(Mnemosyne.MockEmbedding, :embed_batch, fn texts, _opts ->
        vectors = Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)
        {:ok, %Embedding.Response{vectors: vectors, model: "test", usage: %{}}}
      end)

      infra = start_infra_with_timeouts(tmp_dir, true, 50, 100)
      pid = start_session(infra)
      monitor_ref = Process.monitor(pid)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "obs1", "act1")

      # Flush should fire at ~50ms, session timeout at ~100ms
      # Session timeout should wait for flush extraction to complete before stopping
      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}, 2000
      assert map_size(MemoryStore.get_graph(infra.memory_store).nodes) > 0
    end
  end

  describe "timer reset on append" do
    test "appending resets timers so flush does not fire prematurely", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()

      infra = start_infra_with_timeouts(tmp_dir, true, 80, :infinity)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "obs1", "act1")

      Process.sleep(50)
      :ok = Session.append(pid, "obs2", "act2")

      Process.sleep(50)

      assert Session.state(pid) == :collecting
      assert map_size(MemoryStore.get_graph(infra.memory_store).nodes) == 0
    end
  end

  describe "no timers when auto_commit is false" do
    test "no timers fire when auto_commit is disabled", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()

      infra = start_infra_with_timeouts(tmp_dir, false, 50, 100)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "obs1", "act1")

      Process.sleep(200)

      assert Process.alive?(pid)
      assert Session.state(pid) == :collecting
      assert map_size(MemoryStore.get_graph(infra.memory_store).nodes) == 0
    end
  end

  describe "catch-all for unhandled events" do
    test "idle returns invalid_operation for unknown calls", %{tmp_dir: tmp_dir} do
      infra = start_infra(tmp_dir)
      pid = start_session(infra)

      assert {:error, %SessionError{reason: :invalid_operation}} =
               GenStateMachine.call(pid, :something_weird)
    end

    test "collecting returns invalid_operation for unknown calls", %{tmp_dir: tmp_dir} do
      infra = start_infra(tmp_dir)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "goal")

      assert {:error, %SessionError{reason: :invalid_operation}} =
               GenStateMachine.call(pid, :something_weird)
    end
  end

  # -- Integration Tests --

  defp stub_extraction_with_boundary_control do
    call_count = :counters.new(1, [:atomics])

    stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
      {:ok, %LLM.Response{content: "0.5", model: "test", usage: %{}}}
    end)

    stub(Mnemosyne.MockEmbedding, :embed, fn _text, _opts ->
      count = :counters.get(call_count, 1)
      :counters.add(call_count, 1, 1)
      embedding = alternating_embedding(count)
      {:ok, %Embedding.Response{vectors: [embedding], model: "test", usage: %{}}}
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
            %{facts: [%{proposition: "extracted fact", concepts: ["concept_a", "concept_b"]}]}

          String.contains?(system_content, "actionable instructions") ->
            %{
              instructions: [
                %{
                  intent: "do something",
                  condition: "when needed",
                  instruction: "run this",
                  expected_outcome: "it works"
                }
              ]
            }

          String.contains?(system_content, "prescription quality") ->
            %{scores: [%{index: 0, return_score: 0.85}]}

          true ->
            %{}
        end

      {:ok, %LLM.Response{content: content, model: "test", usage: %{}}}
    end)

    stub(Mnemosyne.MockEmbedding, :embed_batch, fn texts, _opts ->
      vectors = Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)
      {:ok, %Embedding.Response{vectors: vectors, model: "test", usage: %{}}}
    end)

    call_count
  end

  describe "integration: full auto-commit lifecycle" do
    test "first trajectory auto-committed, second extracted on close", %{tmp_dir: tmp_dir} do
      stub_extraction_with_boundary_control()

      infra = start_infra_with_auto_commit(tmp_dir, true)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "integration test goal")

      :ok = Session.append(pid, "obs1", "act1")
      :ok = Session.append(pid, "obs2", "act2")
      :ok = Session.append(pid, "obs3", "act3")

      assert_eventually(map_size(MemoryStore.get_graph(infra.memory_store).nodes) > 0)
      assert Session.state(pid) == :collecting

      nodes_before_close = map_size(MemoryStore.get_graph(infra.memory_store).nodes)
      assert nodes_before_close > 0

      :ok = Session.close(pid)
      assert_eventually(Session.state(pid) == :idle)

      nodes_after_close = map_size(MemoryStore.get_graph(infra.memory_store).nodes)
      assert nodes_after_close >= nodes_before_close
    end
  end

  describe "integration: timeout lifecycle" do
    test "flush timeout extracts trajectory, session timeout terminates", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      stub_trajectory_extraction_success()

      infra = start_infra_with_timeouts(tmp_dir, true, 50, 200)
      pid = start_session(infra)
      monitor_ref = Process.monitor(pid)

      :ok = Session.start_episode(pid, "timeout test")
      :ok = Session.append(pid, "obs1", "act1")

      assert_eventually(map_size(MemoryStore.get_graph(infra.memory_store).nodes) > 0)

      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}, 2000
    end
  end

  describe "integration: manual mode backward compatibility" do
    test "auto_commit false preserves full manual flow", %{tmp_dir: tmp_dir} do
      stub_extraction_success()

      infra = start_infra_with_auto_commit(tmp_dir, false)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "manual test")
      :ok = Session.append(pid, "obs1", "act1")
      :ok = Session.append(pid, "obs2", "act2")

      assert map_size(MemoryStore.get_graph(infra.memory_store).nodes) == 0

      :ok = Session.close(pid)
      assert Session.state(pid) == :extracting

      assert_eventually(Session.state(pid) == :ready)

      assert map_size(MemoryStore.get_graph(infra.memory_store).nodes) == 0

      :ok = Session.commit(pid)
      assert Session.state(pid) == :idle

      assert_eventually(map_size(MemoryStore.get_graph(infra.memory_store).nodes) > 0)
    end
  end

  describe "integration: close_and_commit with auto-commit" do
    test "succeeds when close goes straight to idle (all committed)", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode_with_boundary()
      stub_trajectory_extraction_success()

      infra = start_infra_with_auto_commit(tmp_dir, true)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "obs1", "act1")
      :ok = Session.append(pid, "obs2", "act2")

      assert_eventually(map_size(MemoryStore.get_graph(infra.memory_store).nodes) > 0)

      assert :ok = close_and_commit_direct(pid)
      assert Session.state(pid) == :idle
    end

    test "succeeds when close triggers extraction for remaining trajectory", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      stub_trajectory_extraction_success()

      infra = start_infra_with_auto_commit(tmp_dir, true)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "obs1", "act1")

      :ok = Session.close(pid)
      assert_eventually(Session.state(pid) == :idle)

      assert map_size(MemoryStore.get_graph(infra.memory_store).nodes) > 0
    end
  end

  describe "integration: rapid appends with boundaries" do
    test "multiple boundaries handled without race conditions", %{tmp_dir: tmp_dir} do
      call_count = :counters.new(1, [:atomics])

      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        {:ok, %LLM.Response{content: "0.5", model: "test", usage: %{}}}
      end)

      stub(Mnemosyne.MockEmbedding, :embed, fn _text, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        embedding =
          if rem(count, 3) == 2 do
            for i <- 1..128, do: if(rem(i, 2) == 0, do: 0.9, else: -0.9)
          else
            List.duplicate(0.1, 128)
          end

        {:ok, %Embedding.Response{vectors: [embedding], model: "test", usage: %{}}}
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
              %{facts: [%{proposition: "rapid fact", concepts: ["rapid_concept"]}]}

            String.contains?(system_content, "actionable instructions") ->
              %{
                instructions: [
                  %{
                    intent: "rapid intent",
                    condition: "cond",
                    instruction: "instr",
                    expected_outcome: "outcome"
                  }
                ]
              }

            String.contains?(system_content, "prescription quality") ->
              %{scores: [%{index: 0, return_score: 0.85}]}

            true ->
              %{}
          end

        {:ok, %LLM.Response{content: content, model: "test", usage: %{}}}
      end)

      stub(Mnemosyne.MockEmbedding, :embed_batch, fn texts, _opts ->
        vectors = Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)
        {:ok, %Embedding.Response{vectors: vectors, model: "test", usage: %{}}}
      end)

      infra = start_infra_with_auto_commit(tmp_dir, true)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "rapid test")
      :ok = Session.append(pid, "obs1", "act1")
      :ok = Session.append(pid, "obs2", "act2")
      :ok = Session.append(pid, "obs3", "act3")
      :ok = Session.append(pid, "obs4", "act4")
      :ok = Session.append(pid, "obs5", "act5")

      assert_eventually(map_size(MemoryStore.get_graph(infra.memory_store).nodes) > 0)

      assert Session.state(pid) == :collecting

      :ok = Session.close(pid)
      assert_eventually(Session.state(pid) == :idle)

      final_nodes = map_size(MemoryStore.get_graph(infra.memory_store).nodes)
      assert final_nodes > 0
    end
  end

  describe "pending ops queue" do
    defp stub_slow_extraction do
      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        Process.sleep(500)
        {:ok, %LLM.Response{content: "0.5", model: "test", usage: %{}}}
      end)

      stub(Mnemosyne.MockLLM, :chat_structured, fn messages, _schema, _opts ->
        Process.sleep(500)

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

            String.contains?(system_content, "prescription quality") ->
              %{scores: [%{index: 0, return_score: 0.85}]}

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

    test "commit_async queues during extracting and drains on success", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      infra = start_infra(tmp_dir)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "obs", "act")

      stub_slow_extraction()

      :ok = Session.close(pid)
      assert Session.state(pid) == :extracting

      test_pid = self()

      assert :ok =
               Session.commit_async(pid, fn result ->
                 send(test_pid, {:commit_cb, result})
               end)

      assert_receive {:commit_cb, {:ok, :committed}}, 5_000
      assert_eventually(Session.state(pid) == :idle)
    end

    test "commit_async returns error for invalid projected state", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      infra = start_infra(tmp_dir)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "obs", "act")

      stub_slow_extraction()

      :ok = Session.close(pid)
      assert Session.state(pid) == :extracting

      assert :ok = Session.commit_async(pid, nil)

      assert {:error, %SessionError{reason: :invalid_queued_operation}} =
               Session.commit_async(pid, nil)
    end

    test "queued ops chain: commit then start_episode", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      infra = start_infra(tmp_dir)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "obs", "act")

      stub_slow_extraction()

      :ok = Session.close(pid)
      assert Session.state(pid) == :extracting

      test_pid = self()

      assert :ok =
               Session.commit_async(pid, fn result ->
                 send(test_pid, {:commit_cb, result})
               end)

      assert :ok =
               Session.start_episode_async(pid, "next goal", fn result ->
                 send(test_pid, {:start_cb, result})
               end)

      assert_receive {:commit_cb, {:ok, :committed}}, 5_000
      assert_receive {:start_cb, {:ok, :started}}, 5_000
      assert_eventually(Session.state(pid) == :collecting)
    end

    test "extraction failure flushes queue with error callbacks", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      infra = start_infra(tmp_dir)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "obs", "act")

      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        Process.sleep(300)
        {:error, :extraction_boom}
      end)

      stub(Mnemosyne.MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        Process.sleep(300)
        {:error, :extraction_boom}
      end)

      :ok = Session.close(pid)

      test_pid = self()

      assert :ok =
               Session.commit_async(pid, fn result ->
                 send(test_pid, {:commit_cb, result})
               end)

      assert :ok =
               Session.start_episode_async(pid, "next goal", fn result ->
                 send(test_pid, {:start_cb, result})
               end)

      assert_receive {:commit_cb, {:error, %SessionError{reason: :extraction_failed}}}, 5_000
      assert_receive {:start_cb, {:error, %SessionError{reason: :extraction_failed}}}, 5_000
      assert_eventually(Session.state(pid) == :failed)
    end

    test "queue depth limit", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      infra = start_infra(tmp_dir)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "obs", "act")

      stub_slow_extraction()

      :ok = Session.close(pid)
      assert Session.state(pid) == :extracting

      assert :ok = Session.commit_async(pid, nil)
      assert :ok = Session.start_episode_async(pid, "g1", nil)
      assert :ok = Session.close_async(pid, nil)
      assert :ok = Session.commit_async(pid, nil)
      assert :ok = Session.start_episode_async(pid, "g2", nil)

      assert {:error, %SessionError{reason: :pending_queue_full}} =
               Session.close_async(pid, nil)
    end

    test "sync commit still rejects during extracting", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      infra = start_infra(tmp_dir)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "obs", "act")

      stub_slow_extraction()

      :ok = Session.close(pid)
      assert Session.state(pid) == :extracting

      assert {:error, %SessionError{reason: :extraction_in_progress}} = Session.commit(pid)
    end

    test "async ops execute immediately when not busy", %{tmp_dir: tmp_dir} do
      infra = start_infra(tmp_dir)
      pid = start_session(infra)

      test_pid = self()

      assert :ok =
               Session.start_episode_async(pid, "goal", fn result ->
                 send(test_pid, {:start_cb, result})
               end)

      assert_receive {:start_cb, {:ok, :started}}, 1_000
      assert Session.state(pid) == :collecting
    end

    test "auto-commit: start_episode_async queues from extracting", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      infra = start_infra_with_auto_commit(tmp_dir, true)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "obs", "act")

      stub_slow_extraction()

      :ok = Session.close(pid)
      assert Session.state(pid) == :extracting

      test_pid = self()

      assert :ok =
               Session.start_episode_async(pid, "next goal", fn result ->
                 send(test_pid, {:start_cb, result})
               end)

      assert_receive {:start_cb, {:ok, :started}}, 5_000
      assert_eventually(Session.state(pid) == :collecting)
    end

    test "auto-commit: commit_async rejected from extracting", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      infra = start_infra_with_auto_commit(tmp_dir, true)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "obs", "act")

      stub_slow_extraction()

      :ok = Session.close(pid)
      assert Session.state(pid) == :extracting

      assert {:error, %SessionError{reason: :invalid_queued_operation}} =
               Session.commit_async(pid, nil)
    end

    test "close_async queues during collecting with in-flight trajectory tasks",
         %{tmp_dir: tmp_dir} do
      stub_llm_for_episode_with_boundary()

      stub(Mnemosyne.MockLLM, :chat_structured, fn messages, _schema, _opts ->
        system_content =
          messages
          |> Enum.find(%{content: ""}, &(&1.role == :system))
          |> Map.get(:content, "")

        if String.contains?(system_content, "subgoal") do
          {:ok,
           %LLM.Response{
             content: %{"reasoning" => "analysis", "subgoal" => "test subgoal"},
             model: "test",
             usage: %{}
           }}
        else
          Process.sleep(500)

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

              String.contains?(system_content, "prescription quality") ->
                %{scores: [%{index: 0, return_score: 0.85}]}

              true ->
                %{}
            end

          {:ok, %LLM.Response{content: content, model: "test", usage: %{}}}
        end
      end)

      stub(Mnemosyne.MockEmbedding, :embed_batch, fn texts, _opts ->
        vectors = Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)
        {:ok, %Embedding.Response{vectors: vectors, model: "test", usage: %{}}}
      end)

      infra = start_infra_with_auto_commit(tmp_dir, true)
      pid = start_session(infra)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "first obs", "first act")
      :ok = Session.append(pid, "second obs", "second act")

      Process.sleep(50)

      test_pid = self()

      assert :ok =
               Session.close_async(pid, fn result ->
                 send(test_pid, {:close_cb, result})
               end)

      assert Session.state(pid) == :collecting

      assert_receive {:close_cb, {:ok, :closed}}, 5_000
      assert_eventually(Session.state(pid) in [:extracting, :ready, :idle])
    end
  end

  defp close_and_commit_direct(server) do
    :ok = Session.close(server)

    Enum.reduce_while(1..200, :timeout, fn _, _ ->
      case Session.state(server) do
        :extracting ->
          Process.sleep(50)
          {:cont, :timeout}

        :ready ->
          {:halt, Session.commit(server)}

        :idle ->
          {:halt, :ok}

        _other ->
          {:halt, {:error, :unexpected_state}}
      end
    end)
  end
end
