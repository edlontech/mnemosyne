defmodule Mnemosyne.Graph.ChangesetTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Episodic
  alias Mnemosyne.Graph.Node.Intent
  alias Mnemosyne.Graph.Node.Procedural
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Source
  alias Mnemosyne.Graph.Node.Subgoal
  alias Mnemosyne.Graph.Node.Tag
  alias Mnemosyne.NodeMetadata

  describe "new/0" do
    test "returns empty changeset" do
      cs = Changeset.new()
      assert cs.additions == []
      assert cs.links == []
    end
  end

  describe "add_node/2" do
    test "prepends node to additions" do
      tag = %Tag{id: "t1", label: "test"}

      episodic = %Episodic{
        id: "e1",
        observation: "obs",
        action: "act",
        state: "s",
        subgoal: "goal",
        reward: 1.0,
        trajectory_id: "traj1"
      }

      cs =
        Changeset.new()
        |> Changeset.add_node(tag)
        |> Changeset.add_node(episodic)

      assert [%Episodic{id: "e1"}, %Tag{id: "t1"}] = cs.additions
    end

    test "assigns the current runtime timestamp to every node type" do
      before = DateTime.utc_now()

      cs = Enum.reduce(all_nodes(), Changeset.new(), &Changeset.add_node(&2, &1))

      after_add = DateTime.utc_now()

      assert length(cs.additions) == 7

      for node <- cs.additions do
        assert %DateTime{} = node.created_at
        assert DateTime.compare(node.created_at, before) in [:eq, :gt]
        assert DateTime.compare(node.created_at, after_add) in [:eq, :lt]
      end
    end

    test "nodes added at different times receive different timestamps" do
      first = %Tag{id: "first", label: "first"}
      second = %Tag{id: "second", label: "second"}

      cs = Changeset.add_node(Changeset.new(), first)
      Process.sleep(2)
      cs = Changeset.add_node(cs, second)

      [stored_second, stored_first] = cs.additions
      assert DateTime.compare(stored_second.created_at, stored_first.created_at) == :gt
    end

    test "preserves explicit historical timestamps for every node type" do
      historical = ~U[2020-01-01 00:00:00Z]

      for node <- all_nodes() do
        cs = Changeset.add_node(Changeset.new(), %{node | created_at: historical})
        assert [stored] = cs.additions
        assert stored.created_at == historical
      end
    end
  end

  describe "add_link/4" do
    test "prepends 3-tuple link to links" do
      cs =
        Changeset.new()
        |> Changeset.add_link("a", "b", :membership)
        |> Changeset.add_link("c", "d", :sibling)

      assert [{"c", "d", :sibling}, {"a", "b", :membership}] = cs.links
    end

    test "preserves edge type in link tuple" do
      cs =
        Changeset.new()
        |> Changeset.add_link("x", "y", :hierarchical)
        |> Changeset.add_link("p", "q", :provenance)

      assert [{"p", "q", :provenance}, {"x", "y", :hierarchical}] = cs.links
    end
  end

  describe "put_metadata/3" do
    test "associates metadata with a node ID" do
      meta = NodeMetadata.new(cumulative_reward: 1.5, reward_count: 2)

      cs =
        Changeset.put_metadata(Changeset.new(), "node_1", meta)

      assert %NodeMetadata{cumulative_reward: 1.5, reward_count: 2} = cs.metadata["node_1"]
    end

    test "overwrites existing metadata for the same node ID" do
      meta1 = NodeMetadata.new(cumulative_reward: 1.0)
      meta2 = NodeMetadata.new(cumulative_reward: 2.0)

      cs =
        Changeset.new()
        |> Changeset.put_metadata("node_1", meta1)
        |> Changeset.put_metadata("node_1", meta2)

      assert cs.metadata["node_1"].cumulative_reward == 2.0
    end
  end

  defp all_nodes do
    [
      %Episodic{
        id: "episodic",
        observation: "obs",
        action: "act",
        state: "state",
        subgoal: "goal",
        reward: 1.0,
        trajectory_id: "trajectory"
      },
      %Semantic{id: "semantic", proposition: "fact", confidence: 1.0},
      %Procedural{
        id: "procedural",
        instruction: "act",
        condition: "condition",
        expected_outcome: "outcome"
      },
      %Source{id: "source", episode_id: "episodic", step_index: 0},
      %Subgoal{id: "subgoal", description: "goal"},
      %Tag{id: "tag", label: "concept"},
      %Intent{id: "intent", description: "intent"}
    ]
  end

  describe "merge/2" do
    test "concatenates additions and 3-tuple links from both changesets" do
      tag = %Tag{id: "t1", label: "test"}

      episodic = %Episodic{
        id: "e1",
        observation: "obs",
        action: "act",
        state: "s",
        subgoal: "goal",
        reward: 1.0,
        trajectory_id: "traj1"
      }

      cs1 =
        Changeset.new()
        |> Changeset.add_node(tag)
        |> Changeset.add_link("a", "b", :membership)

      cs2 =
        Changeset.new()
        |> Changeset.add_node(episodic)
        |> Changeset.add_link("c", "d", :sibling)

      merged = Changeset.merge(cs1, cs2)

      assert length(merged.additions) == 2
      assert length(merged.links) == 2
      assert Enum.any?(merged.additions, &match?(%Tag{id: "t1"}, &1))
      assert Enum.any?(merged.additions, &match?(%Episodic{id: "e1"}, &1))
      assert {"a", "b", :membership} in merged.links
      assert {"c", "d", :sibling} in merged.links
    end

    test "merges metadata maps from both changesets" do
      meta1 = NodeMetadata.new(cumulative_reward: 1.0)
      meta2 = NodeMetadata.new(cumulative_reward: 2.0)

      cs1 = Changeset.put_metadata(Changeset.new(), "a", meta1)
      cs2 = Changeset.put_metadata(Changeset.new(), "b", meta2)

      merged = Changeset.merge(cs1, cs2)

      assert map_size(merged.metadata) == 2
      assert merged.metadata["a"].cumulative_reward == 1.0
      assert merged.metadata["b"].cumulative_reward == 2.0
    end

    test "right changeset metadata wins on key conflict" do
      meta1 = NodeMetadata.new(cumulative_reward: 1.0)
      meta2 = NodeMetadata.new(cumulative_reward: 5.0)

      cs1 = Changeset.put_metadata(Changeset.new(), "x", meta1)
      cs2 = Changeset.put_metadata(Changeset.new(), "x", meta2)

      merged = Changeset.merge(cs1, cs2)

      assert merged.metadata["x"].cumulative_reward == 5.0
    end
  end
end
