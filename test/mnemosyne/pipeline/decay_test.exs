defmodule Mnemosyne.Pipeline.DecayTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Config
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Intent
  alias Mnemosyne.Graph.Node.Procedural
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Tag
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.NodeMetadata
  alias Mnemosyne.Pipeline.Decay

  @config %Config{
    llm: %{model: "test:model", opts: %{}},
    embedding: %{model: "test:embed", opts: %{}},
    overrides: %{},
    value_function: %{
      module: Mnemosyne.ValueFunction.Default,
      params: %{
        semantic: %{lambda: 0.01, k: 5, base_floor: 0.3, beta: 1.0},
        procedural: %{lambda: 0.01, k: 5, base_floor: 0.3, beta: 1.0}
      }
    }
  }

  defp build_backend(changeset, metadata \\ %{}) do
    {:ok, bs} = InMemory.init([])
    {:ok, bs} = InMemory.apply_changeset(changeset, bs)

    {:ok, bs} =
      if map_size(metadata) > 0,
        do: InMemory.update_metadata(metadata, bs),
        else: {:ok, bs}

    bs
  end

  defp old_time, do: ~U[2025-01-01 00:00:00Z]

  describe "decay/1 with empty graph" do
    test "returns zero deleted and checked" do
      bs = build_backend(Changeset.new())

      assert {:ok, %{deleted: 0, checked: 0}, {InMemory, _bs}} =
               Decay.decay(backend: {InMemory, bs}, config: @config)
    end
  end

  describe "decay/1 deletes old unused nodes" do
    test "semantic node with zero access and old timestamp gets deleted" do
      sem = %Semantic{
        id: "sem_old",
        proposition: "stale fact",
        confidence: 1.0,
        embedding: [1.0, 0.0, 0.0]
      }

      cs = Changeset.add_node(Changeset.new(), sem)

      meta =
        NodeMetadata.new(
          created_at: old_time(),
          access_count: 0,
          cumulative_reward: 0.0,
          reward_count: 0
        )

      bs = build_backend(cs, %{"sem_old" => meta})

      assert {:ok, %{deleted: 1, checked: 1}, {InMemory, final_bs}} =
               Decay.decay(backend: {InMemory, bs}, config: @config)

      {:ok, node, _} = InMemory.get_node("sem_old", final_bs)
      assert is_nil(node)
    end
  end

  describe "decay/1 keeps frequently accessed recent nodes" do
    test "node with high access count and recent activity survives" do
      sem = %Semantic{
        id: "sem_active",
        proposition: "useful fact",
        confidence: 1.0,
        embedding: [1.0, 0.0, 0.0]
      }

      cs = Changeset.add_node(Changeset.new(), sem)

      meta =
        NodeMetadata.new(
          created_at: DateTime.utc_now(),
          access_count: 20,
          last_accessed_at: DateTime.utc_now(),
          cumulative_reward: 2.0,
          reward_count: 2
        )

      bs = build_backend(cs, %{"sem_active" => meta})

      assert {:ok, %{deleted: 0, checked: 1}, {InMemory, final_bs}} =
               Decay.decay(backend: {InMemory, bs}, config: @config)

      {:ok, node, _} = InMemory.get_node("sem_active", final_bs)
      assert node.id == "sem_active"
    end
  end

  describe "decay/1 orphaned Tag cleanup" do
    test "deletes Tag whose only child was decayed" do
      sem = %Semantic{
        id: "sem_old",
        proposition: "stale fact",
        confidence: 1.0,
        embedding: [1.0, 0.0, 0.0]
      }

      tag = %Tag{id: "tag_1", label: "concept", embedding: [0.5, 0.5, 0.0]}

      cs =
        Changeset.new()
        |> Changeset.add_node(sem)
        |> Changeset.add_node(tag)
        |> Changeset.add_link("sem_old", "tag_1", :membership)

      meta =
        NodeMetadata.new(
          created_at: old_time(),
          access_count: 0,
          cumulative_reward: 0.0,
          reward_count: 0
        )

      bs = build_backend(cs, %{"sem_old" => meta, "tag_1" => NodeMetadata.new()})

      assert {:ok, %{deleted: deleted}, {InMemory, final_bs}} =
               Decay.decay(backend: {InMemory, bs}, config: @config)

      assert deleted == 2

      {:ok, tag_node, _} = InMemory.get_node("tag_1", final_bs)
      assert is_nil(tag_node)
    end
  end

  describe "decay/1 orphaned Intent cleanup" do
    test "deletes Intent whose only child was decayed" do
      proc = %Procedural{
        id: "proc_old",
        instruction: "old instruction",
        condition: "never",
        expected_outcome: "nothing",
        embedding: [1.0, 0.0, 0.0]
      }

      intent = %Intent{id: "intent_1", description: "old goal", embedding: [0.5, 0.5, 0.0]}

      cs =
        Changeset.new()
        |> Changeset.add_node(proc)
        |> Changeset.add_node(intent)
        |> Changeset.add_link("proc_old", "intent_1", :hierarchical)

      meta =
        NodeMetadata.new(
          created_at: old_time(),
          access_count: 0,
          cumulative_reward: 0.0,
          reward_count: 0
        )

      bs =
        build_backend(cs, %{
          "proc_old" => meta,
          "intent_1" => NodeMetadata.new()
        })

      assert {:ok, %{deleted: deleted}, {InMemory, final_bs}} =
               Decay.decay(
                 backend: {InMemory, bs},
                 config: @config,
                 node_types: [:procedural]
               )

      assert deleted == 2

      {:ok, intent_node, _} = InMemory.get_node("intent_1", final_bs)
      assert is_nil(intent_node)
    end
  end

  describe "decay/1 custom node_types" do
    test "only checks specified node types" do
      sem = %Semantic{
        id: "sem_old",
        proposition: "stale semantic",
        confidence: 1.0,
        embedding: [1.0, 0.0, 0.0]
      }

      proc = %Procedural{
        id: "proc_old",
        instruction: "stale proc",
        condition: "never",
        expected_outcome: "nothing",
        embedding: [0.0, 1.0, 0.0]
      }

      cs =
        Changeset.new()
        |> Changeset.add_node(sem)
        |> Changeset.add_node(proc)

      old_meta =
        NodeMetadata.new(
          created_at: old_time(),
          access_count: 0,
          cumulative_reward: 0.0,
          reward_count: 0
        )

      bs = build_backend(cs, %{"sem_old" => old_meta, "proc_old" => old_meta})

      assert {:ok, %{deleted: 1, checked: 1}, {InMemory, final_bs}} =
               Decay.decay(
                 backend: {InMemory, bs},
                 config: @config,
                 node_types: [:procedural]
               )

      {:ok, sem_node, _} = InMemory.get_node("sem_old", final_bs)
      assert sem_node.id == "sem_old"

      {:ok, proc_node, _} = InMemory.get_node("proc_old", final_bs)
      assert is_nil(proc_node)
    end
  end

  describe "decay/1 metadata cleanup" do
    test "deletes metadata for both decayed nodes and orphaned routing nodes" do
      sem = %Semantic{
        id: "sem_old",
        proposition: "stale fact",
        confidence: 1.0,
        embedding: [1.0, 0.0, 0.0]
      }

      tag = %Tag{id: "tag_1", label: "concept", embedding: [0.5, 0.5, 0.0]}

      cs =
        Changeset.new()
        |> Changeset.add_node(sem)
        |> Changeset.add_node(tag)
        |> Changeset.add_link("sem_old", "tag_1", :membership)

      old_meta =
        NodeMetadata.new(
          created_at: old_time(),
          access_count: 0,
          cumulative_reward: 0.0,
          reward_count: 0
        )

      tag_meta = NodeMetadata.new()

      bs = build_backend(cs, %{"sem_old" => old_meta, "tag_1" => tag_meta})

      {:ok, _result, {InMemory, final_bs}} =
        Decay.decay(backend: {InMemory, bs}, config: @config)

      {:ok, sem_meta, _} = InMemory.get_metadata(["sem_old"], final_bs)
      {:ok, tag_meta_after, _} = InMemory.get_metadata(["tag_1"], final_bs)

      assert sem_meta == %{}
      assert tag_meta_after == %{}
    end
  end

  describe "decay/1 Tag with partial children surviving" do
    test "Tag is NOT deleted when it still has a surviving child" do
      sem_old = %Semantic{
        id: "sem_old",
        proposition: "stale fact",
        confidence: 1.0,
        embedding: [1.0, 0.0, 0.0]
      }

      sem_active = %Semantic{
        id: "sem_active",
        proposition: "useful fact",
        confidence: 1.0,
        embedding: [0.0, 1.0, 0.0]
      }

      tag = %Tag{id: "tag_1", label: "shared concept", embedding: [0.5, 0.5, 0.0]}

      cs =
        Changeset.new()
        |> Changeset.add_node(sem_old)
        |> Changeset.add_node(sem_active)
        |> Changeset.add_node(tag)
        |> Changeset.add_link("sem_old", "tag_1", :membership)
        |> Changeset.add_link("sem_active", "tag_1", :membership)

      old_meta =
        NodeMetadata.new(
          created_at: old_time(),
          access_count: 0,
          cumulative_reward: 0.0,
          reward_count: 0
        )

      active_meta =
        NodeMetadata.new(
          created_at: DateTime.utc_now(),
          access_count: 20,
          last_accessed_at: DateTime.utc_now(),
          cumulative_reward: 2.0,
          reward_count: 2
        )

      bs =
        build_backend(cs, %{
          "sem_old" => old_meta,
          "sem_active" => active_meta,
          "tag_1" => NodeMetadata.new()
        })

      assert {:ok, %{deleted: 1, checked: 2}, {InMemory, final_bs}} =
               Decay.decay(backend: {InMemory, bs}, config: @config)

      {:ok, tag_node, _} = InMemory.get_node("tag_1", final_bs)
      assert tag_node.id == "tag_1"
      assert tag_node.links |> Map.values() |> Enum.any?(&(MapSet.size(&1) > 0))

      {:ok, surviving, _} = InMemory.get_node("sem_active", final_bs)
      assert surviving.id == "sem_active"

      {:ok, deleted, _} = InMemory.get_node("sem_old", final_bs)
      assert is_nil(deleted)
    end
  end

  describe "decay/1 with nil metadata" do
    test "node with nil metadata scores 0.0 and gets deleted" do
      sem = %Semantic{
        id: "sem_no_meta",
        proposition: "no metadata fact",
        confidence: 1.0,
        embedding: [1.0, 0.0, 0.0]
      }

      cs = Changeset.add_node(Changeset.new(), sem)
      bs = build_backend(cs)

      assert {:ok, %{deleted: 1, checked: 1}, {InMemory, final_bs}} =
               Decay.decay(backend: {InMemory, bs}, config: @config)

      {:ok, node, _} = InMemory.get_node("sem_no_meta", final_bs)
      assert is_nil(node)
    end
  end
end
