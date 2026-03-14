defmodule Mnemosyne.RepoTelemetryTest do
  use ExUnit.Case, async: false

  alias Mnemosyne.Config
  alias Mnemosyne.GraphBackends.InMemory

  @moduletag :tmp_dir

  defp build_config do
    {:ok, config} =
      Zoi.parse(Config.t(), %{
        llm: %{model: "test-model", opts: %{}},
        embedding: %{model: "test-embed", opts: %{}}
      })

    config
  end

  defp start_supervisor(tmp_dir) do
    sup_name = :"mne_sup_tel_#{System.unique_integer([:positive])}"
    dets_path = Path.join(tmp_dir, "repo_telemetry_test.dets")

    sup_opts = [
      name: sup_name,
      config: build_config(),
      llm: Mnemosyne.MockLLM,
      embedding: Mnemosyne.MockEmbedding
    ]

    start_supervised!({Mnemosyne.Supervisor, sup_opts})
    {sup_name, dets_path}
  end

  defp attach_telemetry(event_name) do
    test_pid = self()
    handler_id = "test-#{inspect(event_name)}-#{System.unique_integer()}"

    :telemetry.attach(
      handler_id,
      event_name,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "repo open telemetry" do
    test "emits start and stop events with repo_id", %{tmp_dir: tmp_dir} do
      attach_telemetry([:mnemosyne, :repo, :open, :start])
      attach_telemetry([:mnemosyne, :repo, :open, :stop])

      {sup_name, dets_path} = start_supervisor(tmp_dir)
      repo_id = "telemetry-test-repo"

      persistence =
        {Mnemosyne.GraphBackends.Persistence.DETS, path: dets_path}

      {:ok, _pid} =
        Mnemosyne.open_repo(repo_id,
          supervisor: sup_name,
          backend: {InMemory, persistence: persistence}
        )

      assert_received {:telemetry, [:mnemosyne, :repo, :open, :start], %{monotonic_time: _},
                       %{repo_id: ^repo_id}}

      assert_received {:telemetry, [:mnemosyne, :repo, :open, :stop], %{duration: _},
                       %{repo_id: ^repo_id}}
    end
  end

  describe "repo close telemetry" do
    test "emits start and stop events with repo_id", %{tmp_dir: tmp_dir} do
      attach_telemetry([:mnemosyne, :repo, :close, :start])
      attach_telemetry([:mnemosyne, :repo, :close, :stop])

      {sup_name, dets_path} = start_supervisor(tmp_dir)
      repo_id = "telemetry-close-repo"

      persistence =
        {Mnemosyne.GraphBackends.Persistence.DETS, path: dets_path}

      {:ok, _pid} =
        Mnemosyne.open_repo(repo_id,
          supervisor: sup_name,
          backend: {InMemory, persistence: persistence}
        )

      :ok = Mnemosyne.close_repo(repo_id, supervisor: sup_name)

      assert_received {:telemetry, [:mnemosyne, :repo, :close, :start], %{monotonic_time: _},
                       %{repo_id: ^repo_id}}

      assert_received {:telemetry, [:mnemosyne, :repo, :close, :stop], %{duration: _},
                       %{repo_id: ^repo_id}}
    end
  end
end
