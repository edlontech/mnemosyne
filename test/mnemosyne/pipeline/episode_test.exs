defmodule Mnemosyne.Pipeline.EpisodeTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.LLM
  alias Mnemosyne.Pipeline.Episode

  @default_opts [llm: Mnemosyne.MockLLM, embedding: Mnemosyne.MockEmbedding]
  @test_config %Config{
    llm: %{model: "test:model", opts: %{}},
    embedding: %{model: "test:embed", opts: %{}},
    overrides: %{}
  }

  defp stub_llm_responses(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    Mnemosyne.MockLLM
    |> stub(:chat, fn _messages, _opts ->
      content =
        Agent.get_and_update(agent, fn
          [head | tail] -> {head, tail}
          [] -> {"default", []}
        end)

      {:ok, %LLM.Response{content: content, model: "mock:test", usage: %{}}}
    end)
  end

  defp stub_embedding do
    Mnemosyne.MockEmbedding
    |> stub(:embed, fn _text, _opts ->
      {:ok,
       %Embedding.Response{vectors: [List.duplicate(0.1, 128)], model: "mock:embed", usage: %{}}}
    end)
    |> stub(:embed_batch, fn texts, _opts ->
      vectors = Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)
      {:ok, %Embedding.Response{vectors: vectors, model: "mock:embed", usage: %{}}}
    end)
  end

  defp stub_append_cycle(subgoal \\ "Navigate to config", reward \\ "0.8") do
    stub_llm_responses([subgoal, reward, "Agent state summary"])
    stub_embedding()
  end

  describe "new/1" do
    test "creates episode with goal and empty state" do
      episode = Episode.new("Find the answer")

      assert episode.goal == "Find the answer"
      assert episode.steps == []
      assert episode.trajectories == []
      assert episode.closed == false
      assert String.starts_with?(episode.id, "ep_")
      assert String.starts_with?(episode.current_trajectory_id, "traj_")
    end
  end

  describe "append/4" do
    test "adds a step to the episode" do
      stub_append_cycle()
      episode = Episode.new("Test goal")

      assert {:ok, episode} =
               Episode.append(episode, "saw something", "did something", @default_opts)

      assert [step] = episode.steps
      assert step.observation == "saw something"
      assert step.action == "did something"
      assert step.subgoal == "Navigate to config"
      assert step.reward == 0.8
      assert step.index == 0
      assert is_list(step.embedding)
    end

    test "rejects append on closed episode" do
      episode = Episode.new("Test goal")
      {:ok, episode} = Episode.close(episode)

      assert {:error, :episode_closed} =
               Episode.append(episode, "obs", "act", @default_opts)
    end

    test "accepts config option and resolves per-step opts" do
      stub_embedding()

      Mnemosyne.MockLLM
      |> stub(:chat, fn _messages, opts ->
        assert Keyword.get(opts, :model) == "test:model"
        {:ok, %LLM.Response{content: "0.8", model: "mock:test", usage: %{}}}
      end)

      episode = Episode.new("Test goal")
      opts = @default_opts ++ [config: @test_config]

      assert {:ok, _episode} =
               Episode.append(episode, "saw something", "did something", opts)
    end

    test "propagates LLM errors" do
      Mnemosyne.MockLLM
      |> stub(:chat, fn _messages, _opts -> {:error, :llm_failure} end)

      episode = Episode.new("Test goal")

      assert {:error, :llm_failure} =
               Episode.append(episode, "obs", "act", @default_opts)
    end
  end

  describe "close/1" do
    test "closes episode and builds trajectories" do
      stub_append_cycle()
      episode = Episode.new("Test goal")
      {:ok, episode} = Episode.append(episode, "obs1", "act1", @default_opts)

      stub_append_cycle("Same subgoal", "0.9")
      {:ok, episode} = Episode.append(episode, "obs2", "act2", @default_opts)

      {:ok, closed} = Episode.close(episode)

      assert closed.closed == true
      assert [_ | _] = closed.trajectories

      [traj | _] = closed.trajectories
      assert is_binary(traj.id)
      assert is_list(traj.steps)
      assert is_binary(traj.subgoal)
    end

    test "rejects double close" do
      episode = Episode.new("Test goal")
      {:ok, closed} = Episode.close(episode)

      assert {:error, :already_closed} = Episode.close(closed)
    end
  end
end
