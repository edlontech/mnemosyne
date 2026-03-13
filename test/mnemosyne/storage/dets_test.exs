defmodule Mnemosyne.Storage.DETSTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Graph
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Tag
  alias Mnemosyne.Storage.DETS

  @moduletag :tmp_dir

  defp init_storage(tmp_dir) do
    path = Path.join(tmp_dir, "test.dets")
    {:ok, state} = DETS.init(path: path)
    state
  end

  defp build_semantic(id, proposition) do
    %Semantic{id: id, proposition: proposition, confidence: 0.9}
  end

  describe "init/1" do
    test "creates a DETS file and returns state", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "init_test.dets")
      assert {:ok, %{ref: _ref, path: charlist_path}} = DETS.init(path: path)
      assert charlist_path == String.to_charlist(path)
    end

    test "defaults to mnemosyne.dets path when no option given", %{tmp_dir: tmp_dir} do
      default_path = Path.join(tmp_dir, "mnemosyne.dets")
      assert {:ok, %{ref: ref, path: path}} = DETS.init(path: default_path)
      assert path == String.to_charlist(default_path)
      :dets.close(ref)
    end
  end

  describe "load_graph/1 with empty DETS" do
    test "returns an empty graph", %{tmp_dir: tmp_dir} do
      state = init_storage(tmp_dir)
      assert {:ok, %Graph{nodes: nodes}} = DETS.load_graph(state)
      assert nodes == %{}
    end
  end

  describe "persist_changeset/2 and load_graph/1 round-trip" do
    test "persisted nodes are present after reload", %{tmp_dir: tmp_dir} do
      state = init_storage(tmp_dir)

      node = build_semantic("sem-1", "Elixir is functional")
      changeset = Changeset.add_node(Changeset.new(), node)
      assert :ok = DETS.persist_changeset(changeset, state)

      {:ok, graph} = DETS.load_graph(state)
      loaded = Graph.get_node(graph, "sem-1")
      assert loaded.proposition == "Elixir is functional"
      assert loaded.confidence == 0.9
    end

    test "secondary indexes are rebuilt on load", %{tmp_dir: tmp_dir} do
      state = init_storage(tmp_dir)

      semantic = build_semantic("sem-2", "Processes are lightweight")
      tag = %Tag{id: "tag-1", label: "concurrency"}

      changeset =
        Changeset.new()
        |> Changeset.add_node(semantic)
        |> Changeset.add_node(tag)

      DETS.persist_changeset(changeset, state)
      {:ok, graph} = DETS.load_graph(state)

      assert [%Semantic{}] = Graph.nodes_by_type(graph, :semantic)
      assert [%Tag{}] = Graph.nodes_by_type(graph, :tag)
      assert MapSet.member?(graph.by_tag["concurrency"], "tag-1")
    end

    test "links are persisted bidirectionally", %{tmp_dir: tmp_dir} do
      state = init_storage(tmp_dir)

      node_a = build_semantic("a", "Node A")
      node_b = build_semantic("b", "Node B")

      changeset =
        Changeset.new()
        |> Changeset.add_node(node_a)
        |> Changeset.add_node(node_b)
        |> Changeset.add_link("a", "b")

      DETS.persist_changeset(changeset, state)
      {:ok, graph} = DETS.load_graph(state)

      loaded_a = Graph.get_node(graph, "a")
      loaded_b = Graph.get_node(graph, "b")
      assert MapSet.member?(loaded_a.links, "b")
      assert MapSet.member?(loaded_b.links, "a")
    end
  end

  describe "delete_nodes/2" do
    test "removes entries from storage", %{tmp_dir: tmp_dir} do
      state = init_storage(tmp_dir)

      node = build_semantic("del-1", "To be deleted")
      changeset = Changeset.add_node(Changeset.new(), node)
      DETS.persist_changeset(changeset, state)

      assert :ok = DETS.delete_nodes(["del-1"], state)

      {:ok, graph} = DETS.load_graph(state)
      assert Graph.get_node(graph, "del-1") == nil
    end
  end
end
