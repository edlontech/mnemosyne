defmodule Mnemosyne.MaintenanceTelemetryTest do
  use ExUnit.Case, async: false
  use AssertEventually, timeout: 500, interval: 10

  import Mimic

  alias Mnemosyne.Config
  alias Mnemosyne.Graph
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Intent
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Tag
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.GraphBackends.Persistence.DETS
  alias Mnemosyne.MemoryStore
  alias Mnemosyne.NodeMetadata

  @moduletag :tmp_dir

  setup :set_mimic_global

  @test_vector List.duplicate(0.1, 128)
  @test_repo_id "test-repo"

  defp build_config do
    {:ok, config} =
      Zoi.parse(Config.t(), %{
        llm: %{model: "test-model", opts: %{}},
        embedding: %{model: "test-embed", opts: %{}}
      })

    config
  end

  defp start_store(tmp_dir, opts \\ []) do
    dets_path = Path.join(tmp_dir, "telemetry_test.dets")
    persistence = {DETS, path: dets_path}
    task_sup = :"task_sup_maint_tel_#{System.unique_integer([:positive])}"
    name = :"store_maint_tel_#{System.unique_integer([:positive])}"
    start_supervised!({Task.Supervisor, name: task_sup})

    store_opts =
      Keyword.merge(
        [
          name: name,
          repo_id: @test_repo_id,
          backend: {InMemory, persistence: persistence},
          config: build_config(),
          llm: Mnemosyne.MockLLM,
          embedding: Mnemosyne.MockEmbedding,
          task_supervisor: task_sup
        ],
        opts
      )

    start_supervised!({MemoryStore, store_opts}, id: name)
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

  defp seed_semantic_nodes(store, count) do
    nodes =
      for i <- 1..count do
        %Semantic{
          id: "sem_#{i}",
          proposition: "fact #{i}",
          confidence: 0.9,
          embedding: @test_vector
        }
      end

    tag = %Tag{id: "tag_1", label: "concept", embedding: @test_vector}

    links =
      Enum.map(nodes, fn node -> {"tag_1", node.id} end)

    metadata =
      Map.new(
        [{"tag_1", NodeMetadata.new()} | Enum.map(nodes, &{&1.id, NodeMetadata.new()})],
        fn {id, meta} -> {id, meta} end
      )

    cs = %Changeset{additions: [tag | nodes], links: links, metadata: metadata}
    :ok = MemoryStore.apply_changeset(store, cs)
  end

  describe "consolidator telemetry" do
    test "emits start and stop events with repo_id", %{tmp_dir: tmp_dir} do
      attach_telemetry([:mnemosyne, :consolidator, :consolidate, :start])
      attach_telemetry([:mnemosyne, :consolidator, :consolidate, :stop])

      store = start_store(tmp_dir)
      seed_semantic_nodes(store, 3)

      assert_eventually(length(Graph.nodes_by_type(MemoryStore.get_graph(store), :semantic)) == 3)

      :ok = MemoryStore.consolidate_semantics(store)

      assert_receive {:telemetry, [:mnemosyne, :consolidator, :consolidate, :start],
                      %{monotonic_time: _}, %{repo_id: @test_repo_id}},
                     500

      assert_receive {:telemetry, [:mnemosyne, :consolidator, :consolidate, :stop], measurements,
                      %{repo_id: @test_repo_id}},
                     500

      assert is_integer(measurements.duration)
      assert is_integer(measurements.checked)
      assert is_integer(measurements.deleted)
    end
  end

  describe "decay telemetry" do
    test "emits start and stop events with repo_id", %{tmp_dir: tmp_dir} do
      attach_telemetry([:mnemosyne, :decay, :prune, :start])
      attach_telemetry([:mnemosyne, :decay, :prune, :stop])

      store = start_store(tmp_dir)
      seed_semantic_nodes(store, 2)

      assert_eventually(length(Graph.nodes_by_type(MemoryStore.get_graph(store), :semantic)) == 2)

      :ok = MemoryStore.decay_nodes(store)

      assert_receive {:telemetry, [:mnemosyne, :decay, :prune, :start], %{monotonic_time: _},
                      %{repo_id: @test_repo_id}},
                     500

      assert_receive {:telemetry, [:mnemosyne, :decay, :prune, :stop], measurements,
                      %{repo_id: @test_repo_id}},
                     500

      assert is_integer(measurements.duration)
      assert is_integer(measurements.checked)
      assert is_integer(measurements.deleted)
    end
  end

  describe "intent_merger telemetry" do
    test "emits start and stop events when intents present", %{tmp_dir: tmp_dir} do
      attach_telemetry([:mnemosyne, :intent_merger, :merge, :start])
      attach_telemetry([:mnemosyne, :intent_merger, :merge, :stop])

      store = start_store(tmp_dir)

      intent = %Intent{
        id: "int_1",
        description: "handle errors",
        embedding: @test_vector
      }

      sem = %Semantic{
        id: "sem_1",
        proposition: "errors are common",
        confidence: 0.9,
        embedding: @test_vector
      }

      cs = %Changeset{
        additions: [intent, sem],
        links: [{"int_1", "sem_1"}],
        metadata: %{
          "int_1" => NodeMetadata.new(),
          "sem_1" => NodeMetadata.new()
        }
      }

      :ok = MemoryStore.apply_changeset(store, cs)

      assert_receive {:telemetry, [:mnemosyne, :intent_merger, :merge, :start],
                      %{monotonic_time: _}, %{repo_id: @test_repo_id, intent_count: 1}},
                     500

      assert_receive {:telemetry, [:mnemosyne, :intent_merger, :merge, :stop], measurements,
                      %{repo_id: @test_repo_id}},
                     500

      assert is_integer(measurements.duration)
      assert is_integer(measurements.merged)
      assert is_integer(measurements.rewrites)
    end

    test "does not emit telemetry when no intents in changeset", %{tmp_dir: tmp_dir} do
      attach_telemetry([:mnemosyne, :intent_merger, :merge, :start])

      store = start_store(tmp_dir)

      sem = %Semantic{
        id: "sem_1",
        proposition: "a fact",
        confidence: 0.9,
        embedding: @test_vector
      }

      cs = %Changeset{
        additions: [sem],
        links: [],
        metadata: %{"sem_1" => NodeMetadata.new()}
      }

      :ok = MemoryStore.apply_changeset(store, cs)

      assert_eventually(Graph.get_node(MemoryStore.get_graph(store), "sem_1") != nil)

      refute_receive {:telemetry, [:mnemosyne, :intent_merger, :merge, :start], _, _}, 100
    end
  end
end
