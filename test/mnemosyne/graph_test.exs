defmodule Mnemosyne.GraphTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Graph
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Episodic
  alias Mnemosyne.Graph.Node.Helpers
  alias Mnemosyne.Graph.Node.Subgoal
  alias Mnemosyne.Graph.Node.Tag

  defp make_tag(id, label), do: %Tag{id: id, label: label}

  defp make_episodic(id) do
    %Episodic{
      id: id,
      observation: "obs",
      action: "act",
      state: "s",
      subgoal: "goal",
      reward: 1.0,
      trajectory_id: "traj1"
    }
  end

  defp make_subgoal(id, description) do
    %Subgoal{id: id, description: description}
  end

  describe "new/0" do
    test "returns empty graph" do
      g = Graph.new()
      assert g.nodes == %{}
      assert g.by_type == %{}
      assert g.by_tag == %{}
      assert g.by_subgoal == %{}
    end
  end

  describe "put_node/2" do
    test "adds node and indexes by type" do
      g =
        Graph.put_node(Graph.new(), make_episodic("e1"))

      assert %Episodic{id: "e1"} = Graph.get_node(g, "e1")
      assert MapSet.member?(g.by_type[:episodic], "e1")
    end

    test "indexes Tag nodes by label in by_tag" do
      g =
        Graph.put_node(Graph.new(), make_tag("t1", "important"))

      assert MapSet.member?(g.by_tag["important"], "t1")
    end

    test "indexes Subgoal nodes by description in by_subgoal" do
      g =
        Graph.put_node(Graph.new(), make_subgoal("sg1", "fix the bug"))

      assert MapSet.member?(g.by_subgoal["fix the bug"], "sg1")
    end
  end

  describe "get_node/2" do
    test "returns node when it exists" do
      g = Graph.put_node(Graph.new(), make_tag("t1", "x"))
      assert %Tag{id: "t1"} = Graph.get_node(g, "t1")
    end

    test "returns nil when node does not exist" do
      assert Graph.get_node(Graph.new(), "missing") == nil
    end
  end

  describe "nodes_by_type/2" do
    test "returns all nodes of given type" do
      g =
        Graph.new()
        |> Graph.put_node(make_episodic("e1"))
        |> Graph.put_node(make_episodic("e2"))
        |> Graph.put_node(make_tag("t1", "x"))

      episodics = Graph.nodes_by_type(g, :episodic)
      assert length(episodics) == 2
      assert Enum.all?(episodics, &match?(%Episodic{}, &1))
    end

    test "returns empty list for unknown type" do
      assert Graph.nodes_by_type(Graph.new(), :episodic) == []
    end
  end

  describe "link/4" do
    test "creates bidirectional links with edge type" do
      g =
        Graph.new()
        |> Graph.put_node(make_episodic("e1"))
        |> Graph.put_node(make_tag("t1", "x"))
        |> Graph.link("e1", "t1", :membership)

      e1 = Graph.get_node(g, "e1")
      t1 = Graph.get_node(g, "t1")

      assert MapSet.member?(e1.links[:membership], "t1")
      assert MapSet.member?(t1.links[:membership], "e1")
    end

    test "stores links in the correct edge type map" do
      g =
        Graph.new()
        |> Graph.put_node(make_episodic("e1"))
        |> Graph.put_node(make_episodic("e2"))
        |> Graph.link("e1", "e2", :sibling)

      e1 = Graph.get_node(g, "e1")

      assert MapSet.member?(e1.links[:sibling], "e2")
      refute MapSet.member?(e1.links[:membership], "e2")
      refute MapSet.member?(e1.links[:hierarchical], "e2")
      refute MapSet.member?(e1.links[:provenance], "e2")
    end

    test "supports multiple edge types between the same nodes" do
      g =
        Graph.new()
        |> Graph.put_node(make_episodic("e1"))
        |> Graph.put_node(make_episodic("e2"))
        |> Graph.link("e1", "e2", :membership)
        |> Graph.link("e1", "e2", :sibling)

      e1 = Graph.get_node(g, "e1")

      assert MapSet.member?(e1.links[:membership], "e2")
      assert MapSet.member?(e1.links[:sibling], "e2")

      all_ids = Helpers.all_linked_ids(e1)
      assert MapSet.size(all_ids) == 1
      assert MapSet.member?(all_ids, "e2")
    end

    test "is no-op when either node is missing" do
      g =
        Graph.new()
        |> Graph.put_node(make_episodic("e1"))
        |> Graph.link("e1", "missing", :membership)

      e1 = Graph.get_node(g, "e1")
      assert e1 |> Helpers.all_linked_ids() |> MapSet.size() == 0
    end
  end

  describe "apply_changeset/2" do
    test "applies additions then links" do
      cs =
        Changeset.new()
        |> Changeset.add_node(make_episodic("e1"))
        |> Changeset.add_node(make_tag("t1", "label"))
        |> Changeset.add_link("e1", "t1", :membership)

      g = Graph.apply_changeset(Graph.new(), cs)

      assert Graph.get_node(g, "e1") != nil
      assert Graph.get_node(g, "t1") != nil

      e1 = Graph.get_node(g, "e1")
      assert MapSet.member?(e1.links[:membership], "t1")
    end

    test "applies mixed edge types" do
      cs =
        Changeset.new()
        |> Changeset.add_node(make_episodic("e1"))
        |> Changeset.add_node(make_episodic("e2"))
        |> Changeset.add_node(make_tag("t1", "label"))
        |> Changeset.add_link("e1", "t1", :membership)
        |> Changeset.add_link("e1", "e2", :sibling)

      g = Graph.apply_changeset(Graph.new(), cs)

      e1 = Graph.get_node(g, "e1")
      assert MapSet.member?(e1.links[:membership], "t1")
      assert MapSet.member?(e1.links[:sibling], "e2")
      refute MapSet.member?(e1.links[:membership], "e2")
    end
  end

  describe "by_tag index" do
    test "normalizes tag label for by_tag index" do
      g =
        Graph.new()
        |> Graph.put_node(make_tag("t1", "Important"))
        |> Graph.put_node(make_tag("t2", "  important  "))

      assert MapSet.new(["t1", "t2"]) == g.by_tag["important"]
      assert map_size(g.by_tag) == 1
    end

    test "multiple nodes can share a tag label" do
      t1 = make_tag("t1", "shared")
      t2 = make_tag("t2", "shared")

      g =
        Graph.new()
        |> Graph.put_node(t1)
        |> Graph.put_node(t2)

      assert MapSet.size(g.by_tag["shared"]) == 2
    end
  end

  describe "by_subgoal index" do
    test "multiple subgoals can share a description" do
      sg1 = make_subgoal("sg1", "shared goal")
      sg2 = make_subgoal("sg2", "shared goal")

      g =
        Graph.new()
        |> Graph.put_node(sg1)
        |> Graph.put_node(sg2)

      assert MapSet.size(g.by_subgoal["shared goal"]) == 2
    end
  end

  describe "delete_node/2" do
    test "removes node from the graph" do
      g =
        Graph.new()
        |> Graph.put_node(make_episodic("e1"))
        |> Graph.delete_node("e1")

      assert Graph.get_node(g, "e1") == nil
      assert g.nodes == %{}
    end

    test "rebuilds type index after deletion" do
      g =
        Graph.new()
        |> Graph.put_node(make_episodic("e1"))
        |> Graph.put_node(make_episodic("e2"))
        |> Graph.delete_node("e1")

      assert Graph.nodes_by_type(g, :episodic) == [Graph.get_node(g, "e2")]
      refute MapSet.member?(g.by_type[:episodic], "e1")
    end

    test "rebuilds tag index after deletion" do
      g =
        Graph.new()
        |> Graph.put_node(make_tag("t1", "important"))
        |> Graph.put_node(make_tag("t2", "important"))
        |> Graph.delete_node("t1")

      refute MapSet.member?(g.by_tag["important"], "t1")
      assert MapSet.member?(g.by_tag["important"], "t2")
    end

    test "rebuilds subgoal index after deletion" do
      g =
        Graph.new()
        |> Graph.put_node(make_subgoal("sg1", "fix bug"))
        |> Graph.delete_node("sg1")

      assert g.by_subgoal == %{}
    end

    test "is no-op for missing node ID" do
      g = Graph.put_node(Graph.new(), make_episodic("e1"))
      assert Graph.delete_node(g, "missing") == g
    end

    test "removes stale link references from all edge types" do
      g =
        Graph.new()
        |> Graph.put_node(make_episodic("e1"))
        |> Graph.put_node(make_episodic("e2"))
        |> Graph.put_node(make_episodic("e3"))
        |> Graph.link("e1", "e2", :membership)
        |> Graph.link("e1", "e3", :sibling)
        |> Graph.delete_node("e1")

      e2 = Graph.get_node(g, "e2")
      e3 = Graph.get_node(g, "e3")

      refute MapSet.member?(e2.links[:membership], "e1")
      refute MapSet.member?(e3.links[:sibling], "e1")
      assert e2 |> Helpers.all_linked_ids() |> MapSet.size() == 0
      assert e3 |> Helpers.all_linked_ids() |> MapSet.size() == 0
    end
  end
end
