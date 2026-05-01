defmodule Mnemosyne.Pipeline.GraphRepairTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node, as: NodeProtocol
  alias Mnemosyne.Graph.Node.Intent
  alias Mnemosyne.Graph.Node.Procedural
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Tag
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.NodeMetadata
  alias Mnemosyne.Pipeline.GraphRepair

  defp build_backend(changeset, metadata \\ %{}) do
    {:ok, bs} = InMemory.init([])
    {:ok, bs} = InMemory.apply_changeset(changeset, bs)

    {:ok, bs} =
      if map_size(metadata) > 0,
        do: InMemory.update_metadata(metadata, bs),
        else: {:ok, bs}

    bs
  end

  defp drop_node_without_cleanup(bs, id) do
    nodes = Map.delete(bs.graph.nodes, id)
    rebuilt_indexes = rebuild_indexes(nodes)
    %{bs | graph: %{bs.graph | nodes: nodes, by_type: rebuilt_indexes}}
  end

  defp rebuild_indexes(nodes) do
    Enum.reduce(nodes, %{}, fn {id, node}, acc ->
      type = NodeProtocol.node_type(node)
      Map.update(acc, type, MapSet.new([id]), &MapSet.put(&1, id))
    end)
  end

  defp count_dangling(graph) do
    valid_ids = MapSet.new(Map.keys(graph.nodes))

    graph.nodes
    |> Enum.flat_map(fn {_nid, node} ->
      Enum.flat_map(node.links, fn {_et, ids} ->
        Enum.reject(ids, &MapSet.member?(valid_ids, &1))
      end)
    end)
    |> length()
  end

  describe "repair/1 with clean graph" do
    test "returns zero repaired when graph has no dangling refs" do
      sem1 = %Semantic{id: "s1", proposition: "fact 1", confidence: 1.0}
      sem2 = %Semantic{id: "s2", proposition: "fact 2", confidence: 1.0}

      cs =
        Changeset.new()
        |> Changeset.add_node(sem1)
        |> Changeset.add_node(sem2)
        |> Changeset.add_link("s1", "s2", :sibling)

      bs = build_backend(cs)

      assert {:ok, summary, {InMemory, _bs}} = GraphRepair.repair(backend: {InMemory, bs})

      assert summary.repaired_nodes == 0
      assert summary.dangling_refs == 0
      assert summary.orphans_deleted == 0
    end
  end

  describe "repair/1 strips dangling refs" do
    test "removes references to nodes that don't exist in the graph" do
      sem1 = %Semantic{id: "s1", proposition: "survivor 1", confidence: 1.0}
      sem2 = %Semantic{id: "s2", proposition: "survivor 2", confidence: 1.0}
      sem_dead = %Semantic{id: "s_dead", proposition: "to be removed", confidence: 1.0}

      cs =
        Changeset.new()
        |> Changeset.add_node(sem1)
        |> Changeset.add_node(sem2)
        |> Changeset.add_node(sem_dead)
        |> Changeset.add_link("s1", "s_dead", :sibling)
        |> Changeset.add_link("s2", "s_dead", :sibling)
        |> Changeset.add_link("s1", "s2", :sibling)

      bs = build_backend(cs)
      bs = drop_node_without_cleanup(bs, "s_dead")

      assert count_dangling(bs.graph) == 2

      assert {:ok, summary, {InMemory, new_bs}} = GraphRepair.repair(backend: {InMemory, bs})

      assert summary.dangling_refs == 2
      assert summary.repaired_nodes == 2
      assert count_dangling(new_bs.graph) == 0

      assert MapSet.member?(new_bs.graph.nodes["s1"].links[:sibling], "s2")
      refute MapSet.member?(new_bs.graph.nodes["s1"].links[:sibling], "s_dead")
      refute MapSet.member?(new_bs.graph.nodes["s2"].links[:sibling], "s_dead")
    end

    test "strips dangling refs across multiple link types" do
      sem = %Semantic{id: "s1", proposition: "fact", confidence: 1.0}

      proc = %Procedural{
        id: "p1",
        instruction: "do x",
        condition: "always",
        expected_outcome: "done"
      }

      cs =
        Changeset.new()
        |> Changeset.add_node(sem)
        |> Changeset.add_node(proc)
        |> Changeset.add_link("s1", "p1", :provenance)

      bs = build_backend(cs)

      mutated_sem = %{sem | links: %{provenance: MapSet.new(["ghost1", "ghost2", "p1"])}}
      mutated_proc = %{proc | links: %{provenance: MapSet.new(["ghost3", "s1"])}}
      graph = %{bs.graph | nodes: %{"s1" => mutated_sem, "p1" => mutated_proc}}
      bs = %{bs | graph: graph}

      assert count_dangling(bs.graph) == 3

      assert {:ok, summary, {InMemory, new_bs}} = GraphRepair.repair(backend: {InMemory, bs})

      assert summary.dangling_refs == 3
      assert count_dangling(new_bs.graph) == 0
      assert new_bs.graph.nodes["s1"].links[:provenance] == MapSet.new(["p1"])
      assert new_bs.graph.nodes["p1"].links[:provenance] == MapSet.new(["s1"])
    end
  end

  describe "repair/1 deletes orphaned routing nodes" do
    test "deletes tag whose only child was already gone" do
      sem = %Semantic{id: "s1", proposition: "fact", confidence: 1.0}
      tag = %Tag{id: "tag1", label: "concept"}

      cs =
        Changeset.new()
        |> Changeset.add_node(sem)
        |> Changeset.add_node(tag)
        |> Changeset.add_link("tag1", "s1", :membership)

      bs = build_backend(cs)
      bs = drop_node_without_cleanup(bs, "s1")

      assert {:ok, summary, {InMemory, new_bs}} = GraphRepair.repair(backend: {InMemory, bs})

      assert summary.orphans_deleted == 1
      assert "tag1" in summary.orphan_ids
      assert is_nil(new_bs.graph.nodes["tag1"])
    end

    test "deletes orphaned intent" do
      proc = %Procedural{
        id: "p1",
        instruction: "do x",
        condition: "always",
        expected_outcome: "done"
      }

      intent = %Intent{id: "i1", description: "intent"}

      cs =
        Changeset.new()
        |> Changeset.add_node(proc)
        |> Changeset.add_node(intent)
        |> Changeset.add_link("i1", "p1", :hierarchical)

      bs = build_backend(cs)
      bs = drop_node_without_cleanup(bs, "p1")

      assert {:ok, summary, {InMemory, new_bs}} = GraphRepair.repair(backend: {InMemory, bs})

      assert summary.orphans_deleted == 1
      assert "i1" in summary.orphan_ids
      assert is_nil(new_bs.graph.nodes["i1"])
    end

    test "keeps tag with surviving children" do
      sem1 = %Semantic{id: "s1", proposition: "fact1", confidence: 1.0}
      sem2 = %Semantic{id: "s2", proposition: "fact2", confidence: 1.0}
      tag = %Tag{id: "tag1", label: "concept"}

      cs =
        Changeset.new()
        |> Changeset.add_node(sem1)
        |> Changeset.add_node(sem2)
        |> Changeset.add_node(tag)
        |> Changeset.add_link("tag1", "s1", :membership)
        |> Changeset.add_link("tag1", "s2", :membership)

      bs = build_backend(cs)
      bs = drop_node_without_cleanup(bs, "s1")

      assert {:ok, summary, {InMemory, new_bs}} = GraphRepair.repair(backend: {InMemory, bs})

      assert summary.orphans_deleted == 0
      assert %Tag{} = new_bs.graph.nodes["tag1"]
      assert MapSet.size(new_bs.graph.nodes["tag1"].links[:membership]) == 1
    end

    test "drops metadata for orphaned nodes" do
      sem = %Semantic{id: "s1", proposition: "fact", confidence: 1.0}
      tag = %Tag{id: "tag1", label: "concept"}

      cs =
        Changeset.new()
        |> Changeset.add_node(sem)
        |> Changeset.add_node(tag)
        |> Changeset.add_link("tag1", "s1", :membership)

      bs =
        build_backend(cs, %{
          "s1" => NodeMetadata.new(),
          "tag1" => NodeMetadata.new()
        })

      bs = drop_node_without_cleanup(bs, "s1")

      assert {:ok, _summary, {InMemory, new_bs}} = GraphRepair.repair(backend: {InMemory, bs})

      refute Map.has_key?(new_bs.metadata, "tag1")
    end
  end

  describe "repair/1 on empty graph" do
    test "returns zero counts" do
      bs = build_backend(Changeset.new())

      assert {:ok, summary, {InMemory, _bs}} = GraphRepair.repair(backend: {InMemory, bs})

      assert summary == %{
               checked: 0,
               repaired_nodes: 0,
               dangling_refs: 0,
               orphans_deleted: 0,
               orphan_ids: []
             }
    end
  end
end
