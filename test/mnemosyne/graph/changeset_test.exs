defmodule Mnemosyne.Graph.ChangesetTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Episodic
  alias Mnemosyne.Graph.Node.Tag

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

  describe "merge/2" do
    test "concatenates additions and links from both changesets" do
      tag = %Tag{id: "t1", label: "test"}

      episodic = %Episodic{
        id: "e1",
        observation: "obs",
        action: "act",
        state: "s",
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
  end
end
