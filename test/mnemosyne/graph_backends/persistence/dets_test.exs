defmodule Mnemosyne.GraphBackends.Persistence.DETSTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.GraphBackends.Persistence.DETS, as: PersistenceDETS

  @moduletag :tmp_dir

  defp semantic_node(id) do
    %Semantic{id: id, proposition: "fact #{id}", confidence: 0.9}
  end

  describe "init/1" do
    test "opens a DETS file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.dets")
      assert {:ok, state} = PersistenceDETS.init(path: path)
      assert is_map(state)
      :dets.close(state.ref)
    end
  end

  describe "save/2 and load/1" do
    test "round-trips nodes", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "roundtrip.dets")
      {:ok, state} = PersistenceDETS.init(path: path)

      changeset =
        Changeset.new()
        |> Changeset.add_node(semantic_node("s1"))
        |> Changeset.add_node(semantic_node("s2"))

      assert :ok = PersistenceDETS.save(changeset, state)

      {:ok, graph, _metadata} = PersistenceDETS.load(state)
      assert %Semantic{id: "s1"} = graph.nodes["s1"]
      assert %Semantic{id: "s2"} = graph.nodes["s2"]

      :dets.close(state.ref)
    end

    test "preserves links", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "links.dets")
      {:ok, state} = PersistenceDETS.init(path: path)

      changeset =
        Changeset.new()
        |> Changeset.add_node(semantic_node("s1"))
        |> Changeset.add_node(semantic_node("s2"))
        |> Changeset.add_link("s1", "s2", :sibling)

      assert :ok = PersistenceDETS.save(changeset, state)

      {:ok, graph, _metadata} = PersistenceDETS.load(state)
      assert MapSet.member?(Map.get(graph.nodes["s1"].links, :sibling, MapSet.new()), "s2")
      assert MapSet.member?(Map.get(graph.nodes["s2"].links, :sibling, MapSet.new()), "s1")

      :dets.close(state.ref)
    end
  end

  describe "delete/2" do
    test "removes nodes from DETS", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "delete.dets")
      {:ok, state} = PersistenceDETS.init(path: path)

      changeset =
        Changeset.new()
        |> Changeset.add_node(semantic_node("s1"))
        |> Changeset.add_node(semantic_node("s2"))

      :ok = PersistenceDETS.save(changeset, state)
      assert :ok = PersistenceDETS.delete(["s1"], state)

      {:ok, graph, _metadata} = PersistenceDETS.load(state)
      assert is_nil(graph.nodes["s1"])
      assert %Semantic{id: "s2"} = graph.nodes["s2"]

      :dets.close(state.ref)
    end

    test "strips back-references from surviving nodes after reload", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "delete_backrefs.dets")
      {:ok, state} = PersistenceDETS.init(path: path)

      changeset =
        Changeset.new()
        |> Changeset.add_node(semantic_node("s1"))
        |> Changeset.add_node(semantic_node("s2"))
        |> Changeset.add_node(semantic_node("s3"))
        |> Changeset.add_link("s1", "s2", :sibling)
        |> Changeset.add_link("s1", "s3", :sibling)
        |> Changeset.add_link("s2", "s3", :sibling)

      :ok = PersistenceDETS.save(changeset, state)
      :ok = PersistenceDETS.delete(["s1"], state)

      {:ok, graph, _metadata} = PersistenceDETS.load(state)
      s2_siblings = Map.get(graph.nodes["s2"].links, :sibling, MapSet.new())
      s3_siblings = Map.get(graph.nodes["s3"].links, :sibling, MapSet.new())

      refute MapSet.member?(s2_siblings, "s1")
      refute MapSet.member?(s3_siblings, "s1")
      assert MapSet.member?(s2_siblings, "s3")
      assert MapSet.member?(s3_siblings, "s2")

      :dets.close(state.ref)
    end

    test "strips back-references across multiple link types and batched deletes",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "delete_batch.dets")
      {:ok, state} = PersistenceDETS.init(path: path)

      changeset =
        Changeset.new()
        |> Changeset.add_node(semantic_node("dead1"))
        |> Changeset.add_node(semantic_node("dead2"))
        |> Changeset.add_node(semantic_node("survivor"))
        |> Changeset.add_link("survivor", "dead1", :sibling)
        |> Changeset.add_link("survivor", "dead2", :membership)
        |> Changeset.add_link("dead1", "dead2", :provenance)

      :ok = PersistenceDETS.save(changeset, state)
      :ok = PersistenceDETS.delete(["dead1", "dead2"], state)

      {:ok, graph, _metadata} = PersistenceDETS.load(state)
      assert is_nil(graph.nodes["dead1"])
      assert is_nil(graph.nodes["dead2"])

      survivor_links = graph.nodes["survivor"].links
      assert MapSet.size(Map.get(survivor_links, :sibling, MapSet.new())) == 0
      assert MapSet.size(Map.get(survivor_links, :membership, MapSet.new())) == 0

      :dets.close(state.ref)
    end
  end

  describe "save_metadata/2 and load/1" do
    alias Mnemosyne.NodeMetadata

    test "round-trips metadata records", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "meta_roundtrip.dets")
      {:ok, state} = PersistenceDETS.init(path: path)

      meta1 = NodeMetadata.new(created_at: ~U[2025-01-01 00:00:00Z], access_count: 3)
      meta2 = NodeMetadata.new(created_at: ~U[2025-06-01 00:00:00Z])

      :ok = PersistenceDETS.save_metadata(%{"s1" => meta1, "s2" => meta2}, state)

      {:ok, _graph, metadata} = PersistenceDETS.load(state)
      assert %NodeMetadata{access_count: 3} = metadata["s1"]
      assert %NodeMetadata{} = metadata["s2"]

      :dets.close(state.ref)
    end

    test "load distinguishes node records from metadata records", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "mixed.dets")
      {:ok, state} = PersistenceDETS.init(path: path)

      changeset =
        Changeset.add_node(Changeset.new(), semantic_node("s1"))

      :ok = PersistenceDETS.save(changeset, state)

      meta = NodeMetadata.new(created_at: ~U[2025-01-01 00:00:00Z])
      :ok = PersistenceDETS.save_metadata(%{"s1" => meta}, state)

      {:ok, graph, metadata} = PersistenceDETS.load(state)
      assert %Semantic{id: "s1"} = graph.nodes["s1"]
      assert %NodeMetadata{} = metadata["s1"]

      :dets.close(state.ref)
    end
  end

  describe "delete_metadata/2" do
    alias Mnemosyne.NodeMetadata

    test "removes metadata entries", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "meta_delete.dets")
      {:ok, state} = PersistenceDETS.init(path: path)

      meta = NodeMetadata.new(created_at: ~U[2025-01-01 00:00:00Z])
      :ok = PersistenceDETS.save_metadata(%{"s1" => meta, "s2" => meta}, state)

      :ok = PersistenceDETS.delete_metadata(["s1"], state)

      {:ok, _graph, metadata} = PersistenceDETS.load(state)
      refute Map.has_key?(metadata, "s1")
      assert Map.has_key?(metadata, "s2")

      :dets.close(state.ref)
    end
  end

  describe "InMemory integration" do
    alias Mnemosyne.GraphBackends.InMemory

    test "survives re-init with DETS persistence", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "integration.dets")
      persistence = {PersistenceDETS, [path: path]}

      {:ok, state} = InMemory.init(persistence: persistence)

      changeset =
        Changeset.new()
        |> Changeset.add_node(semantic_node("s1"))
        |> Changeset.add_node(semantic_node("s2"))
        |> Changeset.add_link("s1", "s2", :sibling)

      {:ok, _state} = InMemory.apply_changeset(changeset, state)

      {:ok, state2} = InMemory.init(persistence: persistence)
      assert {:ok, %Semantic{id: "s1"}, _} = InMemory.get_node("s1", state2)
      assert {:ok, %Semantic{id: "s2"}, _} = InMemory.get_node("s2", state2)

      %Semantic{links: links} = state2.graph.nodes["s1"]
      assert MapSet.member?(Map.get(links, :sibling, MapSet.new()), "s2")

      :dets.close(state2.persistence |> elem(1) |> Map.get(:ref))
    end
  end
end
