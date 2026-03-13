defmodule Mnemosyne.SessionTest do
  use ExUnit.Case, async: false

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
        embedding: %{model: "test-embed", opts: %{}}
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

    stub(Mnemosyne.MockEmbedding, :embed, fn _text, _opts ->
      {:ok, %Embedding.Response{vectors: [List.duplicate(0.1, 128)], model: "test", usage: %{}}}
    end)
  end

  defp stub_extraction_success do
    stub(Mnemosyne.MockLLM, :chat, fn messages, _opts ->
      system_content =
        messages
        |> Enum.find(%{content: ""}, &(&1.role == :system))
        |> Map.get(:content, "")

      content =
        if String.contains?(system_content, "actionable instructions") do
          "WHEN: condition\nDO: action\nEXPECT: outcome"
        else
          "0.5"
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

      Process.sleep(200)
      assert Session.state(pid) == :ready
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

      assert :ok = Session.close(pid)

      Process.sleep(200)
      assert Session.state(pid) == :failed
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

      Process.sleep(200)
      assert Session.state(pid) == :ready

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

      :ok = Session.close(pid)
      Process.sleep(200)
      assert Session.state(pid) == :failed

      stub_extraction_success()
      assert :ok = Session.commit(pid)
      assert Session.state(pid) == :extracting

      Process.sleep(200)
      assert Session.state(pid) == :ready
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

      Process.sleep(200)
      assert Session.state(pid) == :ready

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
      Process.sleep(200)
      assert Session.state(pid) == :failed

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
end
