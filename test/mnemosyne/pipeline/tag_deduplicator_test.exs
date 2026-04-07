defmodule Mnemosyne.Pipeline.TagDeduplicatorTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Tag
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.NodeMetadata
  alias Mnemosyne.Pipeline.TagDeduplicator

  setup :set_mimic_from_context

  @backend_state %InMemory{}
  @base_opts [backend: {InMemory, @backend_state}, repo_id: "test_repo"]

  defp make_tag(id, label) do
    %Tag{id: id, label: label, embedding: [0.1, 0.2, 0.3]}
  end

  defp make_semantic(id) do
    %Semantic{id: id, proposition: "test fact", confidence: 1.0, embedding: [0.1, 0.2]}
  end

  describe "deduplicate/2 with no tags" do
    test "returns changeset unchanged" do
      sem = make_semantic("sem_1")
      cs = Changeset.add_node(Changeset.new(), sem)

      assert {:ok, result} = TagDeduplicator.deduplicate(cs, @base_opts)
      assert result.additions == cs.additions
    end
  end

  describe "deduplicate/2 intra-batch" do
    test "collapses tags with same normalized label within the batch" do
      tag1 = make_tag("tag_1", "Database")
      tag2 = make_tag("tag_2", "database")
      sem = make_semantic("sem_1")

      cs =
        Changeset.new()
        |> Changeset.add_node(tag1)
        |> Changeset.add_node(tag2)
        |> Changeset.add_node(sem)
        |> Changeset.add_link("tag_1", "sem_1", :membership)
        |> Changeset.add_link("tag_2", "sem_1", :membership)

      InMemory
      |> expect(:get_nodes_by_type, fn [:tag], @backend_state ->
        {:ok, [], @backend_state}
      end)

      assert {:ok, result} = TagDeduplicator.deduplicate(cs, @base_opts)

      tag_additions = Enum.filter(result.additions, &match?(%Tag{}, &1))
      assert length(tag_additions) == 1

      [kept_tag] = tag_additions
      assert Enum.all?(result.links, fn {from, _to, _type} -> from == kept_tag.id end)
    end

    test "preserves metadata for kept tag and drops replaced tag metadata" do
      tag1 = make_tag("tag_1", "Elixir")
      tag2 = make_tag("tag_2", "elixir")

      cs =
        Changeset.new()
        |> Changeset.add_node(tag1)
        |> Changeset.add_node(tag2)
        |> Changeset.put_metadata("tag_1", NodeMetadata.new())
        |> Changeset.put_metadata("tag_2", NodeMetadata.new())

      InMemory
      |> expect(:get_nodes_by_type, fn [:tag], @backend_state ->
        {:ok, [], @backend_state}
      end)

      assert {:ok, result} = TagDeduplicator.deduplicate(cs, @base_opts)

      [kept] = Enum.filter(result.additions, &match?(%Tag{}, &1))
      assert Map.has_key?(result.metadata, kept.id)

      dropped_id = if kept.id == "tag_1", do: "tag_2", else: "tag_1"
      refute Map.has_key?(result.metadata, dropped_id)
    end
  end

  describe "deduplicate/2 against graph" do
    test "reuses existing graph tag instead of creating new one" do
      existing_tag = make_tag("tag_existing", "database")
      new_tag = make_tag("tag_new", "Database")
      sem = make_semantic("sem_1")

      cs =
        Changeset.new()
        |> Changeset.add_node(new_tag)
        |> Changeset.add_node(sem)
        |> Changeset.add_link("tag_new", "sem_1", :membership)

      InMemory
      |> expect(:get_nodes_by_type, fn [:tag], @backend_state ->
        {:ok, [existing_tag], @backend_state}
      end)

      assert {:ok, result} = TagDeduplicator.deduplicate(cs, @base_opts)

      tag_additions = Enum.filter(result.additions, &match?(%Tag{}, &1))
      assert tag_additions == []

      assert {"tag_existing", "sem_1", :membership} in result.links
    end

    test "keeps tag when no graph match exists" do
      new_tag = make_tag("tag_new", "elixir")
      sem = make_semantic("sem_1")

      cs =
        Changeset.new()
        |> Changeset.add_node(new_tag)
        |> Changeset.add_node(sem)
        |> Changeset.add_link("tag_new", "sem_1", :membership)

      InMemory
      |> expect(:get_nodes_by_type, fn [:tag], @backend_state ->
        {:ok, [], @backend_state}
      end)

      assert {:ok, result} = TagDeduplicator.deduplicate(cs, @base_opts)

      tag_additions = Enum.filter(result.additions, &match?(%Tag{}, &1))
      assert [%Tag{id: "tag_new"}] = tag_additions
    end
  end

  describe "deduplicate/2 link deduplication" do
    test "removes duplicate links after rewriting" do
      tag1 = make_tag("tag_1", "Database")
      tag2 = make_tag("tag_2", "database")
      sem = make_semantic("sem_1")

      cs =
        Changeset.new()
        |> Changeset.add_node(tag1)
        |> Changeset.add_node(tag2)
        |> Changeset.add_node(sem)
        |> Changeset.add_link("tag_1", "sem_1", :membership)
        |> Changeset.add_link("tag_2", "sem_1", :membership)

      InMemory
      |> expect(:get_nodes_by_type, fn [:tag], @backend_state ->
        {:ok, [], @backend_state}
      end)

      assert {:ok, result} = TagDeduplicator.deduplicate(cs, @base_opts)
      assert length(result.links) == 1
    end
  end

  describe "deduplicate/2 reward propagation" do
    test "propagates reward from replaced tag to surviving tag" do
      tag1 = make_tag("tag_1", "Database")
      tag2 = make_tag("tag_2", "database")

      cs =
        Changeset.new()
        |> Changeset.add_node(tag1)
        |> Changeset.add_node(tag2)
        |> Changeset.put_metadata(
          "tag_1",
          NodeMetadata.new(cumulative_reward: 0.8, reward_count: 1)
        )
        |> Changeset.put_metadata(
          "tag_2",
          NodeMetadata.new(cumulative_reward: 0.6, reward_count: 1)
        )

      InMemory
      |> expect(:get_nodes_by_type, fn [:tag], @backend_state ->
        {:ok, [], @backend_state}
      end)

      assert {:ok, result} = TagDeduplicator.deduplicate(cs, @base_opts)

      [kept] = Enum.filter(result.additions, &match?(%Tag{}, &1))
      meta = result.metadata[kept.id]
      assert %NodeMetadata{} = meta
      assert meta.cumulative_reward > 0.0
      assert meta.reward_count > 0
    end

    test "propagates reward from batch tag to existing graph tag" do
      existing_tag = make_tag("tag_existing", "database")
      new_tag = make_tag("tag_new", "Database")

      cs =
        Changeset.new()
        |> Changeset.add_node(new_tag)
        |> Changeset.put_metadata(
          "tag_new",
          NodeMetadata.new(cumulative_reward: 0.7, reward_count: 1)
        )

      InMemory
      |> expect(:get_nodes_by_type, fn [:tag], @backend_state ->
        {:ok, [existing_tag], @backend_state}
      end)

      assert {:ok, result} = TagDeduplicator.deduplicate(cs, @base_opts)

      refute Map.has_key?(result.metadata, "tag_new")
      target_meta = result.metadata["tag_existing"]
      assert %NodeMetadata{cumulative_reward: 0.7, reward_count: 1} = target_meta
    end

    test "drops metadata without propagation when reward_count is 0" do
      tag1 = make_tag("tag_1", "Elixir")
      tag2 = make_tag("tag_2", "elixir")

      cs =
        Changeset.new()
        |> Changeset.add_node(tag1)
        |> Changeset.add_node(tag2)
        |> Changeset.put_metadata("tag_1", NodeMetadata.new())
        |> Changeset.put_metadata("tag_2", NodeMetadata.new())

      InMemory
      |> expect(:get_nodes_by_type, fn [:tag], @backend_state ->
        {:ok, [], @backend_state}
      end)

      assert {:ok, result} = TagDeduplicator.deduplicate(cs, @base_opts)

      [kept] = Enum.filter(result.additions, &match?(%Tag{}, &1))
      assert Map.has_key?(result.metadata, kept.id)
      dropped_id = if kept.id == "tag_1", do: "tag_2", else: "tag_1"
      refute Map.has_key?(result.metadata, dropped_id)
    end
  end

  describe "deduplicate/2 error handling" do
    test "returns changeset with intra-batch dedup when backend fails" do
      tag = make_tag("tag_1", "database")
      sem = make_semantic("sem_1")

      cs =
        Changeset.new()
        |> Changeset.add_node(tag)
        |> Changeset.add_node(sem)
        |> Changeset.add_link("tag_1", "sem_1", :membership)

      InMemory
      |> expect(:get_nodes_by_type, fn [:tag], @backend_state ->
        {:error, :boom}
      end)

      assert {:ok, result} = TagDeduplicator.deduplicate(cs, @base_opts)

      tag_additions = Enum.filter(result.additions, &match?(%Tag{}, &1))
      assert [%Tag{id: "tag_1"}] = tag_additions
    end
  end
end
