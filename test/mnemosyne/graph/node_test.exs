defmodule Mnemosyne.Graph.NodeTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Graph.Edge
  alias Mnemosyne.Graph.Node
  alias Mnemosyne.Graph.Node.Episodic
  alias Mnemosyne.Graph.Node.Helpers
  alias Mnemosyne.Graph.Node.Intent
  alias Mnemosyne.Graph.Node.Procedural
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Source
  alias Mnemosyne.Graph.Node.Subgoal
  alias Mnemosyne.Graph.Node.Tag

  describe "Episodic" do
    test "creates struct with all required fields" do
      node = %Episodic{
        id: "ep-1",
        observation: "user clicked button",
        action: "navigate",
        state: "idle",
        subgoal: "find settings",
        reward: 1.0,
        trajectory_id: "traj-1"
      }

      assert node.id == "ep-1"
      assert node.observation == "user clicked button"
      assert node.action == "navigate"
      assert node.state == "idle"
      assert node.subgoal == "find settings"
      assert node.reward == 1.0
      assert node.trajectory_id == "traj-1"
    end

    test "has correct defaults" do
      node = %Episodic{
        id: "ep-1",
        observation: "obs",
        action: "act",
        state: "s",
        subgoal: "goal",
        reward: 0.5,
        trajectory_id: "t-1"
      }

      assert node.embedding == nil
      assert node.links == Edge.empty_links()
      assert %DateTime{} = node.created_at
    end

    test "protocol dispatch" do
      links = %{Edge.empty_links() | membership: MapSet.new(["link-1"])}

      node = %Episodic{
        id: "ep-1",
        observation: "obs",
        action: "act",
        state: "s",
        subgoal: "goal",
        reward: 0.5,
        trajectory_id: "t-1",
        embedding: [0.1, 0.2],
        links: links
      }

      assert Node.id(node) == "ep-1"
      assert Node.embedding(node) == [0.1, 0.2]
      assert Node.links(node) == links
      assert Node.links(node, :membership) == MapSet.new(["link-1"])
      assert Node.links(node, :sibling) == MapSet.new()
      assert Node.node_type(node) == :episodic
    end
  end

  describe "Semantic" do
    test "creates struct with all required fields" do
      node = %Semantic{
        id: "sem-1",
        proposition: "the sky is blue",
        confidence: 0.95
      }

      assert node.id == "sem-1"
      assert node.proposition == "the sky is blue"
      assert node.confidence == 0.95
    end

    test "has correct defaults" do
      node = %Semantic{id: "sem-1", proposition: "p", confidence: 0.5}

      assert node.embedding == nil
      assert node.links == Edge.empty_links()
      assert %DateTime{} = node.created_at
    end

    test "protocol dispatch" do
      links = %{Edge.empty_links() | membership: MapSet.new(["l-1"])}

      node = %Semantic{
        id: "sem-1",
        proposition: "p",
        confidence: 0.5,
        embedding: [0.3],
        links: links
      }

      assert Node.id(node) == "sem-1"
      assert Node.embedding(node) == [0.3]
      assert Node.links(node) == links
      assert Node.links(node, :membership) == MapSet.new(["l-1"])
      assert Node.links(node, :hierarchical) == MapSet.new()
      assert Node.node_type(node) == :semantic
    end
  end

  describe "Procedural" do
    test "creates struct with all required fields" do
      node = %Procedural{
        id: "proc-1",
        instruction: "run mix test",
        condition: "code changed",
        expected_outcome: "tests pass"
      }

      assert node.id == "proc-1"
      assert node.instruction == "run mix test"
      assert node.condition == "code changed"
      assert node.expected_outcome == "tests pass"
    end

    test "has correct defaults" do
      node = %Procedural{
        id: "proc-1",
        instruction: "i",
        condition: "c",
        expected_outcome: "o"
      }

      assert node.embedding == nil
      assert node.links == Edge.empty_links()
      assert %DateTime{} = node.created_at
    end

    test "protocol dispatch" do
      node = %Procedural{
        id: "proc-1",
        instruction: "i",
        condition: "c",
        expected_outcome: "o"
      }

      assert Node.id(node) == "proc-1"
      assert Node.embedding(node) == nil
      assert Node.links(node) == Edge.empty_links()
      assert Node.links(node, :provenance) == MapSet.new()
      assert Node.node_type(node) == :procedural
    end
  end

  describe "Tag" do
    test "creates struct with all required fields" do
      node = %Tag{id: "tag-1", label: "important"}

      assert node.id == "tag-1"
      assert node.label == "important"
    end

    test "has correct defaults" do
      node = %Tag{id: "tag-1", label: "l"}

      assert node.embedding == nil
      assert node.links == Edge.empty_links()
      assert %DateTime{} = node.created_at
    end

    test "protocol dispatch" do
      node = %Tag{id: "tag-1", label: "important"}

      assert Node.id(node) == "tag-1"
      assert Node.embedding(node) == nil
      assert Node.links(node) == Edge.empty_links()
      assert Node.links(node, :membership) == MapSet.new()
      assert Node.node_type(node) == :tag
    end
  end

  describe "Intent" do
    test "creates struct with all required fields" do
      node = %Intent{id: "int-1", description: "find relevant docs"}

      assert node.id == "int-1"
      assert node.description == "find relevant docs"
    end

    test "has correct defaults" do
      node = %Intent{id: "int-1", description: "d"}

      assert node.embedding == nil
      assert node.links == Edge.empty_links()
      assert %DateTime{} = node.created_at
    end

    test "protocol dispatch" do
      node = %Intent{id: "int-1", description: "d"}

      assert Node.id(node) == "int-1"
      assert Node.embedding(node) == nil
      assert Node.links(node) == Edge.empty_links()
      assert Node.links(node, :hierarchical) == MapSet.new()
      assert Node.node_type(node) == :intent
    end
  end

  describe "Subgoal" do
    test "creates struct with all required fields" do
      node = %Subgoal{id: "sg-1", description: "finish task"}

      assert node.id == "sg-1"
      assert node.description == "finish task"
    end

    test "has correct defaults" do
      node = %Subgoal{id: "sg-1", description: "d"}

      assert node.embedding == nil
      assert node.links == Edge.empty_links()
      assert node.parent_goal == nil
      assert %DateTime{} = node.created_at
    end

    test "accepts optional parent_goal" do
      node = %Subgoal{id: "sg-1", description: "d", parent_goal: "pg-1"}

      assert node.parent_goal == "pg-1"
    end

    test "protocol dispatch" do
      node = %Subgoal{id: "sg-1", description: "d"}

      assert Node.id(node) == "sg-1"
      assert Node.embedding(node) == nil
      assert Node.links(node) == Edge.empty_links()
      assert Node.links(node, :hierarchical) == MapSet.new()
      assert Node.node_type(node) == :subgoal
    end
  end

  describe "Source" do
    test "creates struct with all required fields" do
      node = %Source{id: "src-1", episode_id: "ep-1", step_index: 3}

      assert node.id == "src-1"
      assert node.episode_id == "ep-1"
      assert node.step_index == 3
    end

    test "has correct defaults" do
      node = %Source{id: "src-1", episode_id: "ep-1", step_index: 0}

      assert node.embedding == nil
      assert node.links == Edge.empty_links()
      assert %DateTime{} = node.created_at
    end

    test "protocol dispatch" do
      node = %Source{id: "src-1", episode_id: "ep-1", step_index: 0}

      assert Node.id(node) == "src-1"
      assert Node.embedding(node) == nil
      assert Node.links(node) == Edge.empty_links()
      assert Node.links(node, :provenance) == MapSet.new()
      assert Node.node_type(node) == :source
    end
  end

  describe "Helpers.all_linked_ids/1" do
    test "returns empty set for node with no links" do
      node = %Semantic{id: "sem-1", proposition: "p", confidence: 0.5}

      assert Helpers.all_linked_ids(node) == MapSet.new()
    end

    test "flattens links across all edge types" do
      links = %{
        membership: MapSet.new(["a", "b"]),
        hierarchical: MapSet.new(["c"]),
        provenance: MapSet.new(),
        sibling: MapSet.new(["d"])
      }

      node = %Semantic{id: "sem-1", proposition: "p", confidence: 0.5, links: links}

      assert Helpers.all_linked_ids(node) == MapSet.new(["a", "b", "c", "d"])
    end
  end
end
