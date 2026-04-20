defmodule Mnemosyne.Pipeline.SemanticConsolidatorTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Config
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node, as: NodeProtocol
  alias Mnemosyne.Graph.Node.Episodic
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Tag
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.NodeMetadata
  alias Mnemosyne.Pipeline.SemanticConsolidator

  @config %Config{
    llm: %{model: "test:model", opts: %{}},
    embedding: %{model: "test:embed", opts: %{}},
    overrides: %{},
    value_function: %{
      module: Mnemosyne.ValueFunction.Default,
      params: %{
        semantic: %{lambda: 0.01, k: 5, base_floor: 0.3, beta: 1.0}
      }
    }
  }

  defp build_backend(changeset, metadata \\ %{}) do
    {:ok, bs} = InMemory.init([])
    {:ok, bs} = InMemory.apply_changeset(changeset, bs)

    {:ok, bs} =
      if map_size(metadata) > 0,
        do: InMemory.update_metadata(metadata, bs),
        else: {:ok, bs}

    bs
  end

  defp similar_embedding, do: [1.0, 0.0, 0.0]
  defp similar_embedding_2, do: [0.99, 0.1, 0.0]
  defp dissimilar_embedding, do: [0.0, 0.0, 1.0]

  defp base_metadata(opts \\ []) do
    NodeMetadata.new(
      created_at: Keyword.get(opts, :created_at, DateTime.utc_now()),
      access_count: Keyword.get(opts, :access_count, 1),
      last_accessed_at: Keyword.get(opts, :last_accessed_at, DateTime.utc_now()),
      cumulative_reward: Keyword.get(opts, :cumulative_reward, 1.0),
      reward_count: Keyword.get(opts, :reward_count, 1)
    )
  end

  describe "consolidate/1 with no semantic nodes" do
    test "returns zero deleted and checked" do
      bs = build_backend(Changeset.new())

      assert {:ok, %{deleted: 0, checked: 0}, {InMemory, _bs}} =
               SemanticConsolidator.consolidate(
                 backend: {InMemory, bs},
                 config: @config
               )
    end
  end

  describe "consolidate/1 with two similar nodes" do
    test "deletes the lower-scored node" do
      sem_a = %Semantic{
        id: "sem_a",
        proposition: "Elixir is functional",
        confidence: 1.0,
        embedding: similar_embedding()
      }

      sem_b = %Semantic{
        id: "sem_b",
        proposition: "Elixir is a functional language",
        confidence: 1.0,
        embedding: similar_embedding_2()
      }

      tag = %Tag{id: "tag_1", label: "elixir", embedding: [0.5, 0.5, 0.0]}

      cs =
        Changeset.new()
        |> Changeset.add_node(sem_a)
        |> Changeset.add_node(sem_b)
        |> Changeset.add_node(tag)
        |> Changeset.add_link("sem_a", "tag_1", :membership)
        |> Changeset.add_link("sem_b", "tag_1", :membership)

      high_score_meta = base_metadata(access_count: 10, cumulative_reward: 5.0, reward_count: 2)
      low_score_meta = base_metadata(access_count: 1, cumulative_reward: 0.1, reward_count: 1)

      bs = build_backend(cs, %{"sem_a" => high_score_meta, "sem_b" => low_score_meta})

      assert {:ok, %{deleted: 1, checked: 2}, {InMemory, final_bs}} =
               SemanticConsolidator.consolidate(
                 backend: {InMemory, bs},
                 config: @config
               )

      {:ok, deleted_node, _} = InMemory.get_node("sem_b", final_bs)
      assert is_nil(deleted_node)

      {:ok, surviving_node, _} = InMemory.get_node("sem_a", final_bs)
      assert surviving_node.id == "sem_a"

      {:ok, meta, _} = InMemory.get_metadata(["sem_b"], final_bs)
      assert meta == %{}
    end
  end

  describe "consolidate/1 with dissimilar nodes" do
    test "both nodes survive when below threshold" do
      sem_a = %Semantic{
        id: "sem_a",
        proposition: "Elixir is functional",
        confidence: 1.0,
        embedding: similar_embedding()
      }

      sem_b = %Semantic{
        id: "sem_b",
        proposition: "Rust is systems-level",
        confidence: 1.0,
        embedding: dissimilar_embedding()
      }

      tag = %Tag{id: "tag_1", label: "programming", embedding: [0.5, 0.5, 0.0]}

      cs =
        Changeset.new()
        |> Changeset.add_node(sem_a)
        |> Changeset.add_node(sem_b)
        |> Changeset.add_node(tag)
        |> Changeset.add_link("sem_a", "tag_1", :membership)
        |> Changeset.add_link("sem_b", "tag_1", :membership)

      bs =
        build_backend(cs, %{
          "sem_a" => base_metadata(),
          "sem_b" => base_metadata()
        })

      assert {:ok, %{deleted: 0, checked: 2}, {InMemory, final_bs}} =
               SemanticConsolidator.consolidate(
                 backend: {InMemory, bs},
                 config: @config
               )

      {:ok, node_a, _} = InMemory.get_node("sem_a", final_bs)
      {:ok, node_b, _} = InMemory.get_node("sem_b", final_bs)
      assert node_a.id == "sem_a"
      assert node_b.id == "sem_b"
    end
  end

  describe "consolidate/1 transitive dedup safety" do
    test "does not delete a node twice when A~B and B~C" do
      emb_base = [1.0, 0.0, 0.0]
      emb_close_1 = [0.99, 0.1, 0.0]
      emb_close_2 = [0.98, 0.15, 0.0]

      sem_a = %Semantic{id: "sem_a", proposition: "fact A", confidence: 1.0, embedding: emb_base}

      sem_b = %Semantic{
        id: "sem_b",
        proposition: "fact B",
        confidence: 1.0,
        embedding: emb_close_1
      }

      sem_c = %Semantic{
        id: "sem_c",
        proposition: "fact C",
        confidence: 1.0,
        embedding: emb_close_2
      }

      tag = %Tag{id: "tag_1", label: "shared", embedding: [0.5, 0.5, 0.0]}

      cs =
        Changeset.new()
        |> Changeset.add_node(sem_a)
        |> Changeset.add_node(sem_b)
        |> Changeset.add_node(sem_c)
        |> Changeset.add_node(tag)
        |> Changeset.add_link("sem_a", "tag_1", :membership)
        |> Changeset.add_link("sem_b", "tag_1", :membership)
        |> Changeset.add_link("sem_c", "tag_1", :membership)

      high_meta = base_metadata(access_count: 10, cumulative_reward: 5.0, reward_count: 2)
      mid_meta = base_metadata(access_count: 5, cumulative_reward: 2.0, reward_count: 1)
      low_meta = base_metadata(access_count: 1, cumulative_reward: 0.1, reward_count: 1)

      bs =
        build_backend(cs, %{
          "sem_a" => high_meta,
          "sem_b" => mid_meta,
          "sem_c" => low_meta
        })

      assert {:ok, %{deleted: deleted, checked: 3}, {InMemory, final_bs}} =
               SemanticConsolidator.consolidate(
                 backend: {InMemory, bs},
                 config: @config
               )

      assert deleted >= 1

      {:ok, node_a, _} = InMemory.get_node("sem_a", final_bs)
      assert node_a.id == "sem_a"
    end
  end

  describe "consolidate/1 metadata cleanup" do
    test "deletes metadata for condemned nodes" do
      sem_a = %Semantic{
        id: "sem_a",
        proposition: "Elixir is functional",
        confidence: 1.0,
        embedding: similar_embedding()
      }

      sem_b = %Semantic{
        id: "sem_b",
        proposition: "Elixir is a functional language",
        confidence: 1.0,
        embedding: similar_embedding_2()
      }

      tag = %Tag{id: "tag_1", label: "elixir", embedding: [0.5, 0.5, 0.0]}

      cs =
        Changeset.new()
        |> Changeset.add_node(sem_a)
        |> Changeset.add_node(sem_b)
        |> Changeset.add_node(tag)
        |> Changeset.add_link("sem_a", "tag_1", :membership)
        |> Changeset.add_link("sem_b", "tag_1", :membership)

      high_meta = base_metadata(access_count: 10, cumulative_reward: 5.0, reward_count: 2)
      low_meta = base_metadata(access_count: 1, cumulative_reward: 0.1, reward_count: 1)

      bs = build_backend(cs, %{"sem_a" => high_meta, "sem_b" => low_meta})

      {:ok, _result, {InMemory, final_bs}} =
        SemanticConsolidator.consolidate(
          backend: {InMemory, bs},
          config: @config
        )

      {:ok, surviving_meta, _} = InMemory.get_metadata(["sem_a"], final_bs)
      {:ok, deleted_meta, _} = InMemory.get_metadata(["sem_b"], final_bs)

      assert Map.has_key?(surviving_meta, "sem_a")
      assert deleted_meta == %{}
    end
  end

  describe "consolidate/1 with nil metadata" do
    test "node with nil metadata scores 0.0 and gets deleted" do
      sem_a = %Semantic{
        id: "sem_a",
        proposition: "Elixir is functional",
        confidence: 1.0,
        embedding: similar_embedding()
      }

      sem_b = %Semantic{
        id: "sem_b",
        proposition: "Elixir is a functional language",
        confidence: 1.0,
        embedding: similar_embedding_2()
      }

      tag = %Tag{id: "tag_1", label: "elixir", embedding: [0.5, 0.5, 0.0]}

      cs =
        Changeset.new()
        |> Changeset.add_node(sem_a)
        |> Changeset.add_node(sem_b)
        |> Changeset.add_node(tag)
        |> Changeset.add_link("sem_a", "tag_1", :membership)
        |> Changeset.add_link("sem_b", "tag_1", :membership)

      bs = build_backend(cs, %{"sem_a" => base_metadata(access_count: 5)})

      assert {:ok, %{deleted: 1, checked: 2}, {InMemory, final_bs}} =
               SemanticConsolidator.consolidate(
                 backend: {InMemory, bs},
                 config: @config
               )

      {:ok, surviving, _} = InMemory.get_node("sem_a", final_bs)
      {:ok, deleted, _} = InMemory.get_node("sem_b", final_bs)
      assert surviving.id == "sem_a"
      assert is_nil(deleted)
    end
  end

  describe "consolidate/1 link transfer" do
    test "winner inherits loser's tag memberships" do
      sem_a = %Semantic{
        id: "sem_a",
        proposition: "Elixir is functional",
        confidence: 1.0,
        embedding: similar_embedding()
      }

      sem_b = %Semantic{
        id: "sem_b",
        proposition: "Elixir is a functional language",
        confidence: 1.0,
        embedding: similar_embedding_2()
      }

      tag_shared = %Tag{id: "tag_shared", label: "elixir", embedding: [0.5, 0.5, 0.0]}
      tag_only_b = %Tag{id: "tag_only_b", label: "functional", embedding: [0.3, 0.7, 0.0]}

      cs =
        Changeset.new()
        |> Changeset.add_node(sem_a)
        |> Changeset.add_node(sem_b)
        |> Changeset.add_node(tag_shared)
        |> Changeset.add_node(tag_only_b)
        |> Changeset.add_link("sem_a", "tag_shared", :membership)
        |> Changeset.add_link("sem_b", "tag_shared", :membership)
        |> Changeset.add_link("sem_b", "tag_only_b", :membership)

      high_meta = base_metadata(access_count: 10, cumulative_reward: 5.0, reward_count: 2)
      low_meta = base_metadata(access_count: 1, cumulative_reward: 0.1, reward_count: 1)

      bs = build_backend(cs, %{"sem_a" => high_meta, "sem_b" => low_meta})

      {:ok, _result, {InMemory, final_bs}} =
        SemanticConsolidator.consolidate(
          backend: {InMemory, bs},
          config: @config
        )

      {:ok, survivor, _} = InMemory.get_node("sem_a", final_bs)
      membership_links = NodeProtocol.links(survivor, :membership)

      assert MapSet.member?(membership_links, "tag_shared")
      assert MapSet.member?(membership_links, "tag_only_b")

      {:ok, tag_b, _} = InMemory.get_node("tag_only_b", final_bs)
      tag_b_links = NodeProtocol.links(tag_b, :membership)
      assert MapSet.member?(tag_b_links, "sem_a")
      refute MapSet.member?(tag_b_links, "sem_b")
    end

    test "winner inherits loser's provenance links" do
      sem_a = %Semantic{
        id: "sem_a",
        proposition: "Elixir is functional",
        confidence: 1.0,
        embedding: similar_embedding()
      }

      sem_b = %Semantic{
        id: "sem_b",
        proposition: "Elixir is a functional language",
        confidence: 1.0,
        embedding: similar_embedding_2()
      }

      ep_a = %Episodic{
        id: "ep_a",
        observation: "obs a",
        action: "act a",
        state: "state a",
        subgoal: "goal a",
        reward: 1.0,
        trajectory_id: "t1"
      }

      ep_b = %Episodic{
        id: "ep_b",
        observation: "obs b",
        action: "act b",
        state: "state b",
        subgoal: "goal b",
        reward: 1.0,
        trajectory_id: "t2"
      }

      tag = %Tag{id: "tag_1", label: "elixir", embedding: [0.5, 0.5, 0.0]}

      cs =
        Changeset.new()
        |> Changeset.add_node(sem_a)
        |> Changeset.add_node(sem_b)
        |> Changeset.add_node(ep_a)
        |> Changeset.add_node(ep_b)
        |> Changeset.add_node(tag)
        |> Changeset.add_link("sem_a", "tag_1", :membership)
        |> Changeset.add_link("sem_b", "tag_1", :membership)
        |> Changeset.add_link("sem_a", "ep_a", :provenance)
        |> Changeset.add_link("sem_b", "ep_b", :provenance)

      high_meta = base_metadata(access_count: 10, cumulative_reward: 5.0, reward_count: 2)
      low_meta = base_metadata(access_count: 1, cumulative_reward: 0.1, reward_count: 1)

      bs = build_backend(cs, %{"sem_a" => high_meta, "sem_b" => low_meta})

      {:ok, _result, {InMemory, final_bs}} =
        SemanticConsolidator.consolidate(
          backend: {InMemory, bs},
          config: @config
        )

      {:ok, survivor, _} = InMemory.get_node("sem_a", final_bs)
      provenance_links = NodeProtocol.links(survivor, :provenance)

      assert MapSet.member?(provenance_links, "ep_a")
      assert MapSet.member?(provenance_links, "ep_b")

      {:ok, ep_b_node, _} = InMemory.get_node("ep_b", final_bs)
      ep_b_provenance = NodeProtocol.links(ep_b_node, :provenance)
      assert MapSet.member?(ep_b_provenance, "sem_a")
      refute MapSet.member?(ep_b_provenance, "sem_b")
    end

    test "winner inherits loser's sibling links" do
      sem_a = %Semantic{
        id: "sem_a",
        proposition: "Elixir is functional",
        confidence: 1.0,
        embedding: similar_embedding()
      }

      sem_b = %Semantic{
        id: "sem_b",
        proposition: "Elixir is a functional language",
        confidence: 1.0,
        embedding: similar_embedding_2()
      }

      sem_c = %Semantic{
        id: "sem_c",
        proposition: "Rust is fast",
        confidence: 1.0,
        embedding: dissimilar_embedding()
      }

      tag = %Tag{id: "tag_1", label: "programming", embedding: [0.5, 0.5, 0.0]}

      cs =
        Changeset.new()
        |> Changeset.add_node(sem_a)
        |> Changeset.add_node(sem_b)
        |> Changeset.add_node(sem_c)
        |> Changeset.add_node(tag)
        |> Changeset.add_link("sem_a", "tag_1", :membership)
        |> Changeset.add_link("sem_b", "tag_1", :membership)
        |> Changeset.add_link("sem_c", "tag_1", :membership)
        |> Changeset.add_link("sem_b", "sem_c", :sibling)

      high_meta = base_metadata(access_count: 10, cumulative_reward: 5.0, reward_count: 2)
      low_meta = base_metadata(access_count: 1, cumulative_reward: 0.1, reward_count: 1)

      bs =
        build_backend(cs, %{
          "sem_a" => high_meta,
          "sem_b" => low_meta,
          "sem_c" => base_metadata(access_count: 3)
        })

      {:ok, _result, {InMemory, final_bs}} =
        SemanticConsolidator.consolidate(
          backend: {InMemory, bs},
          config: @config
        )

      {:ok, survivor, _} = InMemory.get_node("sem_a", final_bs)
      sibling_links = NodeProtocol.links(survivor, :sibling)

      assert MapSet.member?(sibling_links, "sem_c")

      {:ok, sem_c_node, _} = InMemory.get_node("sem_c", final_bs)
      sem_c_siblings = NodeProtocol.links(sem_c_node, :sibling)
      assert MapSet.member?(sem_c_siblings, "sem_a")
      refute MapSet.member?(sem_c_siblings, "sem_b")
    end
  end

  describe "consolidate/1 metadata merging" do
    test "winner metadata accumulates loser's counts and rewards" do
      sem_a = %Semantic{
        id: "sem_a",
        proposition: "Elixir is functional",
        confidence: 1.0,
        embedding: similar_embedding()
      }

      sem_b = %Semantic{
        id: "sem_b",
        proposition: "Elixir is a functional language",
        confidence: 1.0,
        embedding: similar_embedding_2()
      }

      tag = %Tag{id: "tag_1", label: "elixir", embedding: [0.5, 0.5, 0.0]}

      cs =
        Changeset.new()
        |> Changeset.add_node(sem_a)
        |> Changeset.add_node(sem_b)
        |> Changeset.add_node(tag)
        |> Changeset.add_link("sem_a", "tag_1", :membership)
        |> Changeset.add_link("sem_b", "tag_1", :membership)

      winner_meta = base_metadata(access_count: 10, cumulative_reward: 5.0, reward_count: 2)
      loser_meta = base_metadata(access_count: 3, cumulative_reward: 1.5, reward_count: 1)

      bs = build_backend(cs, %{"sem_a" => winner_meta, "sem_b" => loser_meta})

      {:ok, _result, {InMemory, final_bs}} =
        SemanticConsolidator.consolidate(
          backend: {InMemory, bs},
          config: @config
        )

      {:ok, meta, _} = InMemory.get_metadata(["sem_a"], final_bs)
      merged = Map.fetch!(meta, "sem_a")

      assert merged.access_count == 13
      assert merged.cumulative_reward == 6.5
      assert merged.reward_count == 3
    end
  end

  describe "consolidate/1 orphan cleanup" do
    test "removes tags with no remaining children" do
      sem_a = %Semantic{
        id: "sem_a",
        proposition: "Elixir is functional",
        confidence: 1.0,
        embedding: similar_embedding()
      }

      sem_b = %Semantic{
        id: "sem_b",
        proposition: "Elixir is a functional language",
        confidence: 1.0,
        embedding: similar_embedding_2()
      }

      tag_shared = %Tag{id: "tag_shared", label: "elixir", embedding: [0.5, 0.5, 0.0]}
      tag_only_b = %Tag{id: "tag_only_b", label: "functional", embedding: [0.3, 0.7, 0.0]}

      cs =
        Changeset.new()
        |> Changeset.add_node(sem_a)
        |> Changeset.add_node(sem_b)
        |> Changeset.add_node(tag_shared)
        |> Changeset.add_node(tag_only_b)
        |> Changeset.add_link("sem_a", "tag_shared", :membership)
        |> Changeset.add_link("sem_b", "tag_shared", :membership)
        |> Changeset.add_link("sem_b", "tag_only_b", :membership)

      high_meta = base_metadata(access_count: 10, cumulative_reward: 5.0, reward_count: 2)
      low_meta = base_metadata(access_count: 1, cumulative_reward: 0.1, reward_count: 1)

      bs = build_backend(cs, %{"sem_a" => high_meta, "sem_b" => low_meta})

      {:ok, result, {InMemory, final_bs}} =
        SemanticConsolidator.consolidate(
          backend: {InMemory, bs},
          config: @config
        )

      # tag_only_b's link was transferred to sem_a, so it should survive
      {:ok, tag_b, _} = InMemory.get_node("tag_only_b", final_bs)
      assert tag_b.id == "tag_only_b"

      # Both tags should still exist since winner inherited the links
      {:ok, tag_s, _} = InMemory.get_node("tag_shared", final_bs)
      assert tag_s.id == "tag_shared"

      # Only sem_b was deleted (not tags, since links were transferred)
      assert result.deleted == 1
    end

    test "removes truly orphaned tags" do
      sem_a = %Semantic{
        id: "sem_a",
        proposition: "Elixir is functional",
        confidence: 1.0,
        embedding: similar_embedding()
      }

      sem_b = %Semantic{
        id: "sem_b",
        proposition: "Elixir is a functional language",
        confidence: 1.0,
        embedding: similar_embedding_2()
      }

      tag = %Tag{id: "tag_1", label: "elixir", embedding: [0.5, 0.5, 0.0]}
      orphan_tag = %Tag{id: "tag_orphan", label: "orphan", embedding: [0.1, 0.1, 0.1]}

      cs =
        Changeset.new()
        |> Changeset.add_node(sem_a)
        |> Changeset.add_node(sem_b)
        |> Changeset.add_node(tag)
        |> Changeset.add_node(orphan_tag)
        |> Changeset.add_link("sem_a", "tag_1", :membership)
        |> Changeset.add_link("sem_b", "tag_1", :membership)

      high_meta = base_metadata(access_count: 10, cumulative_reward: 5.0, reward_count: 2)
      low_meta = base_metadata(access_count: 1, cumulative_reward: 0.1, reward_count: 1)

      bs = build_backend(cs, %{"sem_a" => high_meta, "sem_b" => low_meta})

      {:ok, result, {InMemory, final_bs}} =
        SemanticConsolidator.consolidate(
          backend: {InMemory, bs},
          config: @config
        )

      {:ok, orphan, _} = InMemory.get_node("tag_orphan", final_bs)
      assert is_nil(orphan)

      # sem_b + tag_orphan
      assert result.deleted == 2
      assert "tag_orphan" in result.deleted_ids
    end
  end

  describe "consolidate/1 cross-loser link remapping" do
    test "sibling link between two losers is remapped to their winners" do
      # sem_b ~ sem_a (winner: sem_a), sem_d ~ sem_c (winner: sem_c)
      # sem_b has sibling link to sem_d
      # After merge: sem_a should have sibling link to sem_c
      sem_a = %Semantic{
        id: "sem_a",
        proposition: "Elixir is functional",
        confidence: 1.0,
        embedding: [1.0, 0.0, 0.0]
      }

      sem_b = %Semantic{
        id: "sem_b",
        proposition: "Elixir is a functional lang",
        confidence: 1.0,
        embedding: [0.99, 0.1, 0.0]
      }

      sem_c = %Semantic{
        id: "sem_c",
        proposition: "Rust is fast",
        confidence: 1.0,
        embedding: [0.0, 1.0, 0.0]
      }

      sem_d = %Semantic{
        id: "sem_d",
        proposition: "Rust is very fast",
        confidence: 1.0,
        embedding: [0.0, 0.99, 0.1]
      }

      tag = %Tag{id: "tag_1", label: "programming", embedding: [0.5, 0.5, 0.0]}

      cs =
        Changeset.new()
        |> Changeset.add_node(sem_a)
        |> Changeset.add_node(sem_b)
        |> Changeset.add_node(sem_c)
        |> Changeset.add_node(sem_d)
        |> Changeset.add_node(tag)
        |> Changeset.add_link("sem_a", "tag_1", :membership)
        |> Changeset.add_link("sem_b", "tag_1", :membership)
        |> Changeset.add_link("sem_c", "tag_1", :membership)
        |> Changeset.add_link("sem_d", "tag_1", :membership)
        |> Changeset.add_link("sem_b", "sem_d", :sibling)

      a_meta = base_metadata(access_count: 10, cumulative_reward: 5.0, reward_count: 2)
      b_meta = base_metadata(access_count: 1, cumulative_reward: 0.1, reward_count: 1)
      c_meta = base_metadata(access_count: 10, cumulative_reward: 5.0, reward_count: 2)
      d_meta = base_metadata(access_count: 1, cumulative_reward: 0.1, reward_count: 1)

      bs =
        build_backend(cs, %{
          "sem_a" => a_meta,
          "sem_b" => b_meta,
          "sem_c" => c_meta,
          "sem_d" => d_meta
        })

      {:ok, _result, {InMemory, final_bs}} =
        SemanticConsolidator.consolidate(
          backend: {InMemory, bs},
          config: @config
        )

      {:ok, node_a, _} = InMemory.get_node("sem_a", final_bs)
      {:ok, node_c, _} = InMemory.get_node("sem_c", final_bs)

      assert node_a != nil
      assert node_c != nil

      a_siblings = NodeProtocol.links(node_a, :sibling)
      c_siblings = NodeProtocol.links(node_c, :sibling)

      assert MapSet.member?(a_siblings, "sem_c")
      assert MapSet.member?(c_siblings, "sem_a")
    end
  end

  describe "consolidate/1 pairwise discovery" do
    test "finds duplicates even without shared tags" do
      sem_a = %Semantic{
        id: "sem_a",
        proposition: "Elixir is functional",
        confidence: 1.0,
        embedding: similar_embedding()
      }

      sem_b = %Semantic{
        id: "sem_b",
        proposition: "Elixir is a functional language",
        confidence: 1.0,
        embedding: similar_embedding_2()
      }

      tag_a = %Tag{id: "tag_a", label: "elixir", embedding: [0.5, 0.5, 0.0]}
      tag_b = %Tag{id: "tag_b", label: "functional", embedding: [0.3, 0.7, 0.0]}

      cs =
        Changeset.new()
        |> Changeset.add_node(sem_a)
        |> Changeset.add_node(sem_b)
        |> Changeset.add_node(tag_a)
        |> Changeset.add_node(tag_b)
        |> Changeset.add_link("sem_a", "tag_a", :membership)
        |> Changeset.add_link("sem_b", "tag_b", :membership)

      high_meta = base_metadata(access_count: 10, cumulative_reward: 5.0, reward_count: 2)
      low_meta = base_metadata(access_count: 1, cumulative_reward: 0.1, reward_count: 1)

      bs = build_backend(cs, %{"sem_a" => high_meta, "sem_b" => low_meta})

      assert {:ok, %{deleted: deleted}, {InMemory, final_bs}} =
               SemanticConsolidator.consolidate(
                 backend: {InMemory, bs},
                 config: @config
               )

      assert deleted >= 1

      {:ok, survivor, _} = InMemory.get_node("sem_a", final_bs)
      assert survivor.id == "sem_a"

      {:ok, deleted_node, _} = InMemory.get_node("sem_b", final_bs)
      assert is_nil(deleted_node)
    end
  end

  describe "consolidate/1 when a node is both winner and loser in different pairs" do
    test "tag links are preserved when node loses to higher-scored and wins against lower-scored" do
      # Order in embeddable list matters: A appears before B, B before C.
      # A (score 5) compared against B (score 10): B wins, A condemned.
      # Inner loop continues for A: A compared against C (score 1): A "wins", C condemned.
      # Tag is linked only to C. The tag's connection must end up on the true surviving node (B),
      # not on A (which is being deleted).
      sem_a = %Semantic{
        id: "sem_a",
        proposition: "Elixir is functional",
        confidence: 1.0,
        embedding: [1.0, 0.0, 0.0]
      }

      sem_b = %Semantic{
        id: "sem_b",
        proposition: "Elixir is a functional language",
        confidence: 1.0,
        embedding: [0.99, 0.1, 0.0]
      }

      sem_c = %Semantic{
        id: "sem_c",
        proposition: "Elixir is functional programming",
        confidence: 1.0,
        embedding: [0.98, 0.15, 0.0]
      }

      tag_only_c = %Tag{id: "tag_only_c", label: "c_tag", embedding: [0.2, 0.8, 0.0]}

      cs =
        Changeset.new()
        |> Changeset.add_node(sem_a)
        |> Changeset.add_node(sem_b)
        |> Changeset.add_node(sem_c)
        |> Changeset.add_node(tag_only_c)
        |> Changeset.add_link("sem_c", "tag_only_c", :membership)

      mid_meta = base_metadata(access_count: 5, cumulative_reward: 2.0, reward_count: 1)
      high_meta = base_metadata(access_count: 20, cumulative_reward: 10.0, reward_count: 4)
      low_meta = base_metadata(access_count: 1, cumulative_reward: 0.1, reward_count: 1)

      bs =
        build_backend(cs, %{
          "sem_a" => mid_meta,
          "sem_b" => high_meta,
          "sem_c" => low_meta
        })

      {:ok, _result, {InMemory, final_bs}} =
        SemanticConsolidator.consolidate(
          backend: {InMemory, bs},
          config: @config
        )

      {:ok, survivor_b, _} = InMemory.get_node("sem_b", final_bs)
      assert survivor_b != nil, "highest-scored node must survive"

      {:ok, tag, _} = InMemory.get_node("tag_only_c", final_bs)

      assert tag != nil,
             "tag linked to a condemned loser must be preserved, attached to the surviving winner"

      tag_links = NodeProtocol.links(tag, :membership)

      assert MapSet.member?(tag_links, "sem_b"),
             "tag must be linked to the true surviving winner (sem_b)"

      b_links = NodeProtocol.links(survivor_b, :membership)
      assert MapSet.member?(b_links, "tag_only_c")
    end
  end
end
