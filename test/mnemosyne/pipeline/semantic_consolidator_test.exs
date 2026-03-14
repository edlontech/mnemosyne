defmodule Mnemosyne.Pipeline.SemanticConsolidatorTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Config
  alias Mnemosyne.Graph.Changeset
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
        |> Changeset.add_link("sem_a", "tag_1")
        |> Changeset.add_link("sem_b", "tag_1")

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
        |> Changeset.add_link("sem_a", "tag_1")
        |> Changeset.add_link("sem_b", "tag_1")

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
        |> Changeset.add_link("sem_a", "tag_1")
        |> Changeset.add_link("sem_b", "tag_1")
        |> Changeset.add_link("sem_c", "tag_1")

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
        |> Changeset.add_link("sem_a", "tag_1")
        |> Changeset.add_link("sem_b", "tag_1")

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
        |> Changeset.add_link("sem_a", "tag_1")
        |> Changeset.add_link("sem_b", "tag_1")

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
end
