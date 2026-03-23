defmodule Mnemosyne.GraphBackends.InMemoryTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Episodic
  alias Mnemosyne.Graph.Node.Procedural
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Subgoal
  alias Mnemosyne.Graph.Node.Tag
  alias Mnemosyne.GraphBackends.InMemory

  @test_vector List.duplicate(0.1, 128)
  @alt_vector List.duplicate(0.2, 128)

  @value_fns %{
    module: Mnemosyne.ValueFunction.Default,
    params: %{
      episodic: %{threshold: 0.0, top_k: 30, lambda: 0.01, k: 5, base_floor: 0.3, beta: 1.0},
      semantic: %{threshold: 0.0, top_k: 20, lambda: 0.01, k: 5, base_floor: 0.3, beta: 1.0},
      tag: %{threshold: 0.9, top_k: 10, lambda: 0.01, k: 5, base_floor: 0.3, beta: 1.0},
      subgoal: %{threshold: 0.75, top_k: 10, lambda: 0.01, k: 5, base_floor: 0.3, beta: 1.0}
    }
  }

  defp semantic_node(id, embedding) do
    %Semantic{id: id, proposition: "fact #{id}", confidence: 0.9, embedding: embedding}
  end

  defp episodic_node(id, embedding) do
    %Episodic{
      id: id,
      observation: "obs #{id}",
      action: "act #{id}",
      state: "state #{id}",
      subgoal: "goal #{id}",
      reward: 1.0,
      trajectory_id: "traj-1",
      embedding: embedding
    }
  end

  defp tag_node(id, label, embedding) do
    %Tag{id: id, label: label, embedding: embedding}
  end

  defp subgoal_node(id, desc, embedding) do
    %Subgoal{id: id, description: desc, embedding: embedding}
  end

  describe "init/1" do
    test "returns empty graph state with no persistence" do
      assert {:ok, state} = InMemory.init([])
      assert %InMemory{persistence: nil} = state
      assert state.graph.nodes == %{}
    end
  end

  describe "apply_changeset/2 and get_node/2" do
    test "adds nodes and retrieves them" do
      {:ok, state} = InMemory.init([])
      node = semantic_node("s1", @test_vector)

      changeset = Changeset.add_node(Changeset.new(), node)
      {:ok, state} = InMemory.apply_changeset(changeset, state)

      assert {:ok, %Semantic{id: "s1"}, _state} = InMemory.get_node("s1", state)
    end

    test "returns nil for missing node" do
      {:ok, state} = InMemory.init([])
      assert {:ok, nil, _state} = InMemory.get_node("missing", state)
    end
  end

  describe "get_linked_nodes/2" do
    test "traverses links and returns linked nodes" do
      {:ok, state} = InMemory.init([])
      n1 = semantic_node("s1", @test_vector)
      n2 = semantic_node("s2", @alt_vector)

      changeset =
        Changeset.new()
        |> Changeset.add_node(n1)
        |> Changeset.add_node(n2)
        |> Changeset.add_link("s1", "s2")

      {:ok, state} = InMemory.apply_changeset(changeset, state)

      {:ok, %Semantic{} = retrieved, state} = InMemory.get_node("s1", state)
      link_ids = MapSet.to_list(retrieved.links)

      {:ok, linked, _state} = InMemory.get_linked_nodes(link_ids, state)
      assert [%Semantic{id: "s2"}] = linked
    end

    test "filters out non-existent node IDs" do
      {:ok, state} = InMemory.init([])
      {:ok, nodes, _state} = InMemory.get_linked_nodes(["nonexistent"], state)
      assert nodes == []
    end
  end

  describe "delete_nodes/2" do
    test "removes nodes from the graph" do
      {:ok, state} = InMemory.init([])
      node = semantic_node("s1", @test_vector)

      changeset = Changeset.add_node(Changeset.new(), node)
      {:ok, state} = InMemory.apply_changeset(changeset, state)
      {:ok, state} = InMemory.delete_nodes(["s1"], state)

      assert {:ok, nil, _state} = InMemory.get_node("s1", state)
    end
  end

  describe "find_candidates/6" do
    test "returns scored nodes filtered by type" do
      {:ok, state} = InMemory.init([])

      s1 = semantic_node("s1", @test_vector)
      e1 = episodic_node("e1", @alt_vector)

      changeset =
        Changeset.new()
        |> Changeset.add_node(s1)
        |> Changeset.add_node(e1)

      {:ok, state} = InMemory.apply_changeset(changeset, state)

      {:ok, candidates, _state} =
        InMemory.find_candidates([:semantic], @test_vector, [], @value_fns, [], state)

      assert [{%Semantic{id: "s1"}, score}] = candidates
      assert is_float(score)
      assert score > 0.0
    end

    test "returns empty list for empty graph" do
      {:ok, state} = InMemory.init([])

      {:ok, candidates, _state} =
        InMemory.find_candidates([:semantic], @test_vector, [], @value_fns, [], state)

      assert candidates == []
    end

    test "respects value function threshold" do
      {:ok, state} = InMemory.init([])

      orthogonal = List.duplicate(0.0, 127) ++ [1.0]
      sg = subgoal_node("sg1", "some goal", orthogonal)

      changeset = Changeset.add_node(Changeset.new(), sg)
      {:ok, state} = InMemory.apply_changeset(changeset, state)

      {:ok, candidates, _state} =
        InMemory.find_candidates([:subgoal], @test_vector, [], @value_fns, [], state)

      assert candidates == []
    end

    test "deduplicates nodes across types" do
      {:ok, state} = InMemory.init([])

      s1 = semantic_node("s1", @test_vector)
      s2 = semantic_node("s2", @test_vector)

      changeset =
        Changeset.new()
        |> Changeset.add_node(s1)
        |> Changeset.add_node(s2)

      {:ok, state} = InMemory.apply_changeset(changeset, state)

      {:ok, candidates, _state} =
        InMemory.find_candidates([:semantic, :semantic], @test_vector, [], @value_fns, [], state)

      ids = Enum.map(candidates, fn {node, _} -> node.id end)
      assert ids == Enum.uniq(ids)
    end

    test "uses tag vectors for scoring" do
      {:ok, state} = InMemory.init([])

      tag = tag_node("t1", "elixir", @test_vector)
      changeset = Changeset.add_node(Changeset.new(), tag)
      {:ok, state} = InMemory.apply_changeset(changeset, state)

      orthogonal_query = List.duplicate(0.0, 127) ++ [1.0]

      {:ok, candidates_no_tags, _} =
        InMemory.find_candidates(
          [:tag],
          orthogonal_query,
          [],
          %{module: Mnemosyne.ValueFunction.Default, params: %{}},
          [],
          state
        )

      {:ok, candidates_with_tags, _} =
        InMemory.find_candidates(
          [:tag],
          orthogonal_query,
          [@test_vector],
          %{module: Mnemosyne.ValueFunction.Default, params: %{}},
          [],
          state
        )

      no_tag_score =
        case candidates_no_tags do
          [{_, s}] -> s
          [] -> 0.0
        end

      assert [{_, with_tag_score}] = candidates_with_tags
      assert with_tag_score > no_tag_score
    end
  end

  defp procedural_node(id, embedding) do
    %Procedural{
      id: id,
      condition: "condition #{id}",
      instruction: "instruction #{id}",
      expected_outcome: "outcome #{id}",
      embedding: embedding
    }
  end

  describe "get_nodes_by_type/2" do
    test "returns nodes of requested types only" do
      {:ok, state} = InMemory.init([])
      s1 = semantic_node("s1", @test_vector)
      e1 = episodic_node("e1", @alt_vector)

      changeset =
        Changeset.new()
        |> Changeset.add_node(s1)
        |> Changeset.add_node(e1)

      {:ok, state} = InMemory.apply_changeset(changeset, state)

      {:ok, nodes, _state} = InMemory.get_nodes_by_type([:semantic], state)

      assert [%Semantic{id: "s1"}] = nodes
    end

    test "returns empty list when no nodes match" do
      {:ok, state} = InMemory.init([])

      {:ok, nodes, _state} = InMemory.get_nodes_by_type([:procedural], state)

      assert nodes == []
    end

    test "returns nodes from multiple types when multiple requested" do
      {:ok, state} = InMemory.init([])
      s1 = semantic_node("s1", @test_vector)
      p1 = procedural_node("p1", @alt_vector)
      e1 = episodic_node("e1", @test_vector)

      changeset =
        Changeset.new()
        |> Changeset.add_node(s1)
        |> Changeset.add_node(p1)
        |> Changeset.add_node(e1)

      {:ok, state} = InMemory.apply_changeset(changeset, state)

      {:ok, nodes, _state} = InMemory.get_nodes_by_type([:semantic, :procedural], state)

      ids = Enum.map(nodes, & &1.id) |> Enum.sort()
      assert ids == ["p1", "s1"]
    end
  end

  describe "metadata callbacks" do
    alias Mnemosyne.NodeMetadata

    setup do
      {:ok, state} = InMemory.init([])
      %{state: state}
    end

    test "get_metadata returns empty map for unknown IDs", %{state: state} do
      {:ok, result, _state} = InMemory.get_metadata(["unknown-1", "unknown-2"], state)
      assert result == %{}
    end

    test "update_metadata stores entries and get_metadata retrieves them", %{state: state} do
      meta = NodeMetadata.new(created_at: ~U[2025-01-01 00:00:00Z])

      {:ok, state} = InMemory.update_metadata(%{"n1" => meta, "n2" => meta}, state)
      {:ok, result, _state} = InMemory.get_metadata(["n1", "n2"], state)

      assert map_size(result) == 2
      assert %NodeMetadata{} = result["n1"]
      assert %NodeMetadata{} = result["n2"]
    end

    test "get_metadata returns only entries for requested IDs", %{state: state} do
      meta = NodeMetadata.new(created_at: ~U[2025-01-01 00:00:00Z])

      {:ok, state} = InMemory.update_metadata(%{"n1" => meta, "n2" => meta}, state)
      {:ok, result, _state} = InMemory.get_metadata(["n1"], state)

      assert map_size(result) == 1
      assert Map.has_key?(result, "n1")
      refute Map.has_key?(result, "n2")
    end

    test "delete_metadata removes entries", %{state: state} do
      meta = NodeMetadata.new(created_at: ~U[2025-01-01 00:00:00Z])

      {:ok, state} = InMemory.update_metadata(%{"n1" => meta, "n2" => meta}, state)
      {:ok, state} = InMemory.delete_metadata(["n1"], state)
      {:ok, result, _state} = InMemory.get_metadata(["n1", "n2"], state)

      assert map_size(result) == 1
      refute Map.has_key?(result, "n1")
      assert Map.has_key?(result, "n2")
    end

    test "update_metadata merges with existing entries", %{state: state} do
      meta1 = NodeMetadata.new(created_at: ~U[2025-01-01 00:00:00Z])
      meta2 = NodeMetadata.new(created_at: ~U[2025-06-01 00:00:00Z], access_count: 5)

      {:ok, state} = InMemory.update_metadata(%{"n1" => meta1}, state)
      {:ok, state} = InMemory.update_metadata(%{"n2" => meta2}, state)
      {:ok, result, _state} = InMemory.get_metadata(["n1", "n2"], state)

      assert result["n1"].created_at == ~U[2025-01-01 00:00:00Z]
      assert result["n2"].access_count == 5
    end
  end
end
