defmodule Mnemosyne.Pipeline.EpisodicValidationTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Config
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Episodic
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Source
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.NodeMetadata
  alias Mnemosyne.Pipeline.EpisodicValidation

  @config %Config{
    llm: %{model: "test:model", opts: %{}},
    embedding: %{model: "test:embed", opts: %{}},
    overrides: %{}
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

  describe "validate/1 with empty graph" do
    test "returns zero stats" do
      bs = build_backend(Changeset.new())

      assert {:ok, %{checked: 0, penalized: 0, orphaned: 0, grounded: 0}, {InMemory, _bs}} =
               EpisodicValidation.validate(backend: {InMemory, bs}, config: @config)
    end
  end

  describe "validate/1 grounded node" do
    test "no penalty when source embedding is similar to semantic node" do
      source = %Source{
        id: "src_1",
        episode_id: "ep_1",
        step_index: 0,
        embedding: [1.0, 0.0, 0.0]
      }

      episodic = %Episodic{
        id: "epi_1",
        observation: "obs",
        action: "act",
        state: "state",
        subgoal: "goal",
        reward: 1.0,
        trajectory_id: "traj_1",
        embedding: [0.9, 0.1, 0.0]
      }

      semantic = %Semantic{
        id: "sem_1",
        proposition: "grounded fact",
        confidence: 1.0,
        embedding: [0.95, 0.05, 0.0]
      }

      cs =
        Changeset.new()
        |> Changeset.add_node(source)
        |> Changeset.add_node(episodic)
        |> Changeset.add_node(semantic)
        |> Changeset.add_link("epi_1", "src_1", :provenance)
        |> Changeset.add_link("sem_1", "epi_1", :provenance)

      meta = NodeMetadata.new(cumulative_reward: 1.0, reward_count: 1)
      bs = build_backend(cs, %{"sem_1" => meta})

      assert {:ok, %{checked: 1, grounded: 1, penalized: 0, orphaned: 0}, {InMemory, final_bs}} =
               EpisodicValidation.validate(backend: {InMemory, bs}, config: @config)

      {:ok, meta_after, _} = InMemory.get_metadata(["sem_1"], final_bs)
      assert meta_after["sem_1"].cumulative_reward == 1.0
    end
  end

  describe "validate/1 weak grounding penalty" do
    test "penalizes when source embedding has low similarity" do
      source = %Source{
        id: "src_1",
        episode_id: "ep_1",
        step_index: 0,
        embedding: [0.0, 0.0, 1.0]
      }

      episodic = %Episodic{
        id: "epi_1",
        observation: "obs",
        action: "act",
        state: "state",
        subgoal: "goal",
        reward: 1.0,
        trajectory_id: "traj_1",
        embedding: [0.0, 0.0, 1.0]
      }

      semantic = %Semantic{
        id: "sem_1",
        proposition: "weakly grounded fact",
        confidence: 1.0,
        embedding: [1.0, 0.0, 0.0]
      }

      cs =
        Changeset.new()
        |> Changeset.add_node(source)
        |> Changeset.add_node(episodic)
        |> Changeset.add_node(semantic)
        |> Changeset.add_link("epi_1", "src_1", :provenance)
        |> Changeset.add_link("sem_1", "epi_1", :provenance)

      meta = NodeMetadata.new(cumulative_reward: 1.0, reward_count: 1)
      bs = build_backend(cs, %{"sem_1" => meta})

      assert {:ok, %{checked: 1, penalized: 1, grounded: 0, orphaned: 0}, {InMemory, final_bs}} =
               EpisodicValidation.validate(backend: {InMemory, bs}, config: @config)

      {:ok, meta_after, _} = InMemory.get_metadata(["sem_1"], final_bs)
      assert meta_after["sem_1"].cumulative_reward == 0.9
    end
  end

  describe "validate/1 orphan penalty" do
    test "penalizes node with no provenance links" do
      semantic = %Semantic{
        id: "sem_orphan",
        proposition: "orphaned fact",
        confidence: 1.0,
        embedding: [1.0, 0.0, 0.0]
      }

      cs = Changeset.add_node(Changeset.new(), semantic)
      meta = NodeMetadata.new(cumulative_reward: 1.0, reward_count: 1)
      bs = build_backend(cs, %{"sem_orphan" => meta})

      assert {:ok, %{checked: 1, orphaned: 1, penalized: 0, grounded: 0}, {InMemory, final_bs}} =
               EpisodicValidation.validate(backend: {InMemory, bs}, config: @config)

      {:ok, meta_after, _} = InMemory.get_metadata(["sem_orphan"], final_bs)
      assert meta_after["sem_orphan"].cumulative_reward == 0.7
    end
  end

  describe "validate/1 penalty floors at 0.0" do
    test "cumulative_reward does not go below zero" do
      semantic = %Semantic{
        id: "sem_zero",
        proposition: "zero reward fact",
        confidence: 1.0,
        embedding: [1.0, 0.0, 0.0]
      }

      cs = Changeset.add_node(Changeset.new(), semantic)
      meta = NodeMetadata.new(cumulative_reward: 0.1, reward_count: 1)
      bs = build_backend(cs, %{"sem_zero" => meta})

      assert {:ok, %{checked: 1, orphaned: 1}, {InMemory, final_bs}} =
               EpisodicValidation.validate(backend: {InMemory, bs}, config: @config)

      {:ok, meta_after, _} = InMemory.get_metadata(["sem_zero"], final_bs)
      assert meta_after["sem_zero"].cumulative_reward == 0.0
    end
  end

  describe "validate/1 with custom config" do
    test "uses episodic_validation config params" do
      semantic = %Semantic{
        id: "sem_custom",
        proposition: "custom config fact",
        confidence: 1.0,
        embedding: [1.0, 0.0, 0.0]
      }

      cs = Changeset.add_node(Changeset.new(), semantic)
      meta = NodeMetadata.new(cumulative_reward: 2.0, reward_count: 1)
      bs = build_backend(cs, %{"sem_custom" => meta})

      config = %{@config | episodic_validation: %{orphan_penalty: 0.5}}

      assert {:ok, %{checked: 1, orphaned: 1}, {InMemory, final_bs}} =
               EpisodicValidation.validate(backend: {InMemory, bs}, config: config)

      {:ok, meta_after, _} = InMemory.get_metadata(["sem_custom"], final_bs)
      assert meta_after["sem_custom"].cumulative_reward == 1.5
    end
  end

  describe "validate/1 with no metadata" do
    test "creates metadata entry with penalty applied" do
      semantic = %Semantic{
        id: "sem_no_meta",
        proposition: "no meta fact",
        confidence: 1.0,
        embedding: [1.0, 0.0, 0.0]
      }

      cs = Changeset.add_node(Changeset.new(), semantic)
      bs = build_backend(cs)

      assert {:ok, %{checked: 1, orphaned: 1}, {InMemory, final_bs}} =
               EpisodicValidation.validate(backend: {InMemory, bs}, config: @config)

      {:ok, meta_after, _} = InMemory.get_metadata(["sem_no_meta"], final_bs)
      assert meta_after["sem_no_meta"].cumulative_reward == 0.0
    end
  end
end
