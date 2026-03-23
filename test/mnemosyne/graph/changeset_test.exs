defmodule Mnemosyne.Graph.ChangesetTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Episodic
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

      assert [^episodic, ^tag] = cs.additions
    end
  end

  describe "add_link/3" do
    test "prepends link tuple to links" do
      cs =
        Changeset.new()
        |> Changeset.add_link("a", "b")
        |> Changeset.add_link("c", "d")

      assert [{"c", "d"}, {"a", "b"}] = cs.links
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

  describe "merge/2" do
    test "concatenates additions and links from both changesets" do
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
        |> Changeset.add_link("a", "b")

      cs2 =
        Changeset.new()
        |> Changeset.add_node(episodic)
        |> Changeset.add_link("c", "d")

      merged = Changeset.merge(cs1, cs2)

      assert length(merged.additions) == 2
      assert length(merged.links) == 2
      assert tag in merged.additions
      assert episodic in merged.additions
      assert {"a", "b"} in merged.links
      assert {"c", "d"} in merged.links
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
