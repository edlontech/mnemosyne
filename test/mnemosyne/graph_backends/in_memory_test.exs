defmodule Mnemosyne.GraphBackends.InMemoryTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Episodic
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Subgoal
  alias Mnemosyne.Graph.Node.Tag
  alias Mnemosyne.GraphBackends.InMemory

  @test_vector List.duplicate(0.1, 128)
  @alt_vector List.duplicate(0.2, 128)

  @value_fns %{
    episodic: Mnemosyne.ValueFunctions.EpisodicRelevant,
    semantic: Mnemosyne.ValueFunctions.SemanticRelevant,
    tag: Mnemosyne.ValueFunctions.TagExact,
    subgoal: Mnemosyne.ValueFunctions.SubgoalMatch
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
        InMemory.find_candidates([:tag], orthogonal_query, [], %{}, [], state)

      {:ok, candidates_with_tags, _} =
        InMemory.find_candidates([:tag], orthogonal_query, [@test_vector], %{}, [], state)

      no_tag_score =
        case candidates_no_tags do
          [{_, s}] -> s
          [] -> 0.0
        end

      assert [{_, with_tag_score}] = candidates_with_tags
      assert with_tag_score > no_tag_score
    end
  end
end
