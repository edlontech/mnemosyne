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

      {:ok, graph} = PersistenceDETS.load(state)
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
        |> Changeset.add_link("s1", "s2")

      assert :ok = PersistenceDETS.save(changeset, state)

      {:ok, graph} = PersistenceDETS.load(state)
      assert MapSet.member?(graph.nodes["s1"].links, "s2")
      assert MapSet.member?(graph.nodes["s2"].links, "s1")

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

      {:ok, graph} = PersistenceDETS.load(state)
      assert is_nil(graph.nodes["s1"])
      assert %Semantic{id: "s2"} = graph.nodes["s2"]

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
        |> Changeset.add_link("s1", "s2")

      {:ok, _state} = InMemory.apply_changeset(changeset, state)

      {:ok, state2} = InMemory.init(persistence: persistence)
      assert {:ok, %Semantic{id: "s1"}, _} = InMemory.get_node("s1", state2)
      assert {:ok, %Semantic{id: "s2"}, _} = InMemory.get_node("s2", state2)

      %Semantic{links: links} = state2.graph.nodes["s1"]
      assert MapSet.member?(links, "s2")

      :dets.close(state2.persistence |> elem(1) |> Map.get(:ref))
    end
  end
end
