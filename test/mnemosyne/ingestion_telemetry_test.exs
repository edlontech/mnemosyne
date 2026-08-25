defmodule Mnemosyne.IngestionTelemetryTest do
  use ExUnit.Case, async: false

  import Mimic

  alias Mnemosyne.Config
  alias Mnemosyne.Errors.Framework.NotFoundError
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.GraphBackends.Persistence.DETS
  alias Mnemosyne.Pipeline.Ingestion
  alias Mnemosyne.Trajectory

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

  defp start_supervisor do
    supervisor = :"ingestion_telemetry_supervisor_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Mnemosyne.Supervisor,
       name: supervisor,
       config: build_config(),
       llm: Mnemosyne.MockLLM,
       embedding: Mnemosyne.MockEmbedding}
    )

    supervisor
  end

  defp open_repo(tmp_dir, supervisor) do
    repo_id = "ingestion-telemetry-repo-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Mnemosyne.open_repo(repo_id,
        supervisor: supervisor,
        backend: {InMemory, persistence: {DETS, path: Path.join(tmp_dir, "#{repo_id}.dets")}}
      )

    repo_id
  end

  defp trajectory(source_id) do
    %Trajectory{
      source_id: source_id,
      goal: "Diagnose timeouts",
      steps: [%{observation: "Timeout", action: "Inspect logs"}],
      metadata: %{}
    }
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

  test "emits ingestion start and stop with node_count", %{tmp_dir: tmp_dir} do
    attach_telemetry([:mnemosyne, :ingestion, :ingest, :start])
    attach_telemetry([:mnemosyne, :ingestion, :ingest, :stop])
    source_id = "telemetry-success"

    stub(Ingestion, :run, fn _trajectory, _opts ->
      {:ok,
       Changeset.add_node(
         Changeset.new(),
         %Semantic{id: "telemetry-node", proposition: "Stored", confidence: 0.9}
       )}
    end)

    supervisor = start_supervisor()
    repo_id = open_repo(tmp_dir, supervisor)

    assert {:ok, _receipt} =
             Mnemosyne.ingest(repo_id, trajectory(source_id), supervisor: supervisor)

    assert_received {:telemetry, [:mnemosyne, :ingestion, :ingest, :start], %{monotonic_time: _},
                     %{repo_id: ^repo_id, source_id: ^source_id}}

    assert_received {:telemetry, [:mnemosyne, :ingestion, :ingest, :stop], measurements,
                     %{repo_id: ^repo_id, source_id: ^source_id}}

    assert is_integer(measurements.duration)
    assert measurements.node_count == 1
  end

  test "emits a stop event without node_count for a structured error" do
    attach_telemetry([:mnemosyne, :ingestion, :ingest, :start])
    attach_telemetry([:mnemosyne, :ingestion, :ingest, :stop])
    source_id = "telemetry-error"
    repo_id = "missing-repo"
    supervisor = start_supervisor()

    assert {:error, %NotFoundError{resource: :repo, id: ^repo_id}} =
             Mnemosyne.ingest(repo_id, trajectory(source_id), supervisor: supervisor)

    assert_received {:telemetry, [:mnemosyne, :ingestion, :ingest, :start], %{monotonic_time: _},
                     %{repo_id: ^repo_id, source_id: ^source_id}}

    assert_received {:telemetry, [:mnemosyne, :ingestion, :ingest, :stop], measurements,
                     %{repo_id: ^repo_id, source_id: ^source_id}}

    refute Map.has_key?(measurements, :node_count)
  end

  test "emits ingestion exception telemetry and reraises lookup exceptions" do
    attach_telemetry([:mnemosyne, :ingestion, :ingest, :start])
    attach_telemetry([:mnemosyne, :ingestion, :ingest, :exception])
    source_id = "telemetry-exception"
    repo_id = "missing-repo"

    assert_raise ArgumentError, ~r/unknown registry/, fn ->
      Mnemosyne.ingest(repo_id, trajectory(source_id), supervisor: :missing_ingestion_supervisor)
    end

    assert_received {:telemetry, [:mnemosyne, :ingestion, :ingest, :start], %{monotonic_time: _},
                     %{repo_id: ^repo_id, source_id: ^source_id}}

    assert_received {:telemetry, [:mnemosyne, :ingestion, :ingest, :exception], %{duration: _},
                     metadata}

    assert %{repo_id: ^repo_id, source_id: ^source_id, kind: :error, reason: %ArgumentError{}} =
             metadata

    assert is_list(metadata.stacktrace)
  end
end
