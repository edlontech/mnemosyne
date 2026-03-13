defmodule Mnemosyne.SessionTelemetryTest do
  use ExUnit.Case, async: false

  import Mimic

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.GraphBackends.Persistence.DETS, as: PersistenceDETS
  alias Mnemosyne.LLM
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
    registry = :"registry_tel_#{System.unique_integer([:positive])}"
    task_sup = :"task_sup_tel_#{System.unique_integer([:positive])}"
    store_name = :"store_tel_#{System.unique_integer([:positive])}"
    dets_path = Path.join(tmp_dir, "session_telemetry_test.dets")

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

    start_supervised!({Mnemosyne.MemoryStore, store_opts}, id: store_name)

    %{
      registry: registry,
      task_supervisor: task_sup,
      memory_store: store_name,
      config: build_config()
    }
  end

  defp start_session(infra) do
    session_opts = [
      registry: infra.registry,
      task_supervisor: infra.task_supervisor,
      memory_store: infra.memory_store,
      config: infra.config,
      llm: Mnemosyne.MockLLM,
      embedding: Mnemosyne.MockEmbedding
    ]

    start_supervised!({Session, session_opts},
      id: :"session_tel_#{System.unique_integer([:positive])}"
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

  defp attach_telemetry(test_pid, event_name) do
    handler_id = "test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      event_name,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "session transition telemetry" do
    test "idle -> collecting emits transition event", %{tmp_dir: tmp_dir} do
      attach_telemetry(self(), [:mnemosyne, :session, :transition, :stop])

      infra = start_infra(tmp_dir)
      pid = start_session(infra)
      session_id = Session.id(pid)

      :ok = Session.start_episode(pid, "test goal")

      assert_receive {:telemetry_event, [:mnemosyne, :session, :transition, :stop],
                      %{duration: 0},
                      %{session_id: ^session_id, from_state: :idle, to_state: :collecting}}
    end

    test "collecting -> extracting emits transition event", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      attach_telemetry(self(), [:mnemosyne, :session, :transition, :stop])

      infra = start_infra(tmp_dir)
      pid = start_session(infra)
      session_id = Session.id(pid)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "saw something", "did something")
      :ok = Session.close(pid)

      assert_receive {:telemetry_event, [:mnemosyne, :session, :transition, :stop],
                      %{duration: 0},
                      %{session_id: ^session_id, from_state: :collecting, to_state: :extracting}}
    end

    test "extracting -> ready emits transition event on success", %{tmp_dir: tmp_dir} do
      stub_extraction_success()
      attach_telemetry(self(), [:mnemosyne, :session, :transition, :stop])

      infra = start_infra(tmp_dir)
      pid = start_session(infra)
      session_id = Session.id(pid)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "saw something", "did something")
      :ok = Session.close(pid)

      assert_receive {:telemetry_event, [:mnemosyne, :session, :transition, :stop],
                      %{duration: 0},
                      %{session_id: ^session_id, from_state: :extracting, to_state: :ready}},
                     2000
    end

    test "extracting -> failed emits transition event on error", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      attach_telemetry(self(), [:mnemosyne, :session, :transition, :stop])

      infra = start_infra(tmp_dir)
      pid = start_session(infra)
      session_id = Session.id(pid)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "saw something", "did something")

      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        {:error, :extraction_failed}
      end)

      :ok = Session.close(pid)

      assert_receive {:telemetry_event, [:mnemosyne, :session, :transition, :stop],
                      %{duration: 0},
                      %{session_id: ^session_id, from_state: :extracting, to_state: :failed}},
                     2000
    end

    test "failed -> idle on discard emits transition event", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      attach_telemetry(self(), [:mnemosyne, :session, :transition, :stop])

      infra = start_infra(tmp_dir)
      pid = start_session(infra)
      session_id = Session.id(pid)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "saw something", "did something")

      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        {:error, :extraction_failed}
      end)

      :ok = Session.close(pid)
      Process.sleep(200)
      assert Session.state(pid) == :failed

      :ok = Session.discard(pid)

      assert_receive {:telemetry_event, [:mnemosyne, :session, :transition, :stop],
                      %{duration: 0},
                      %{session_id: ^session_id, from_state: :failed, to_state: :idle}}
    end

    test "ready -> idle on commit emits transition event", %{tmp_dir: tmp_dir} do
      stub_extraction_success()
      attach_telemetry(self(), [:mnemosyne, :session, :transition, :stop])

      infra = start_infra(tmp_dir)
      pid = start_session(infra)
      session_id = Session.id(pid)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "saw something", "did something")
      :ok = Session.close(pid)

      Process.sleep(200)
      assert Session.state(pid) == :ready

      :ok = Session.commit(pid)

      assert_receive {:telemetry_event, [:mnemosyne, :session, :transition, :stop],
                      %{duration: 0},
                      %{session_id: ^session_id, from_state: :ready, to_state: :idle}}
    end

    test "ready -> idle on discard emits transition event", %{tmp_dir: tmp_dir} do
      stub_extraction_success()
      attach_telemetry(self(), [:mnemosyne, :session, :transition, :stop])

      infra = start_infra(tmp_dir)
      pid = start_session(infra)
      session_id = Session.id(pid)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "saw something", "did something")
      :ok = Session.close(pid)

      Process.sleep(200)
      assert Session.state(pid) == :ready

      :ok = Session.discard(pid)

      assert_receive {:telemetry_event, [:mnemosyne, :session, :transition, :stop],
                      %{duration: 0},
                      %{session_id: ^session_id, from_state: :ready, to_state: :idle}}
    end

    test "failed -> extracting on commit/retry emits transition event", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      attach_telemetry(self(), [:mnemosyne, :session, :transition, :stop])

      infra = start_infra(tmp_dir)
      pid = start_session(infra)
      session_id = Session.id(pid)

      :ok = Session.start_episode(pid, "test goal")
      :ok = Session.append(pid, "saw something", "did something")

      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        {:error, :extraction_failed}
      end)

      :ok = Session.close(pid)
      Process.sleep(200)
      assert Session.state(pid) == :failed

      stub_extraction_success()
      :ok = Session.commit(pid)

      assert_receive {:telemetry_event, [:mnemosyne, :session, :transition, :stop],
                      %{duration: 0},
                      %{session_id: ^session_id, from_state: :failed, to_state: :extracting}}
    end
  end
end
