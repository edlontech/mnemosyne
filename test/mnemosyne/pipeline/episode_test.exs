defmodule Mnemosyne.Pipeline.EpisodeTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.Errors.Invalid.EpisodeError
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

  defp stub_subgoal_only(subgoal \\ "Navigate to config") do
    stub_llm_responses([subgoal])
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
    test "first append stores step with nil reward" do
      stub_subgoal_only()
      episode = Episode.new("Test goal")

      assert {:ok, episode, _trace} =
               Episode.append(episode, "saw something", "did something", @default_opts)

      assert [step] = episode.steps
      assert step.observation == "saw something"
      assert step.action == "did something"
      assert step.subgoal == "Navigate to config"
      assert step.reward == nil
      assert step.index == 0
      assert is_list(step.embedding)
    end

    test "second append scores the previous step using current observation" do
      # First append: subgoal only (no reward call)
      stub_subgoal_only("Navigate to config")
      episode = Episode.new("Test goal")

      {:ok, episode, _trace} =
        Episode.append(episode, "saw something", "did something", @default_opts)

      # Second append: subgoal for step 1 + reward for step 0
      stub_llm_responses(["Explore options", "0.8"])
      stub_embedding()

      {:ok, episode, _trace} =
        Episode.append(episode, "result appeared", "clicked it", @default_opts)

      assert [step_0, step_1] = episode.steps
      assert step_0.reward == 0.8
      assert step_1.reward == nil
    end

    test "rejects append on closed episode" do
      episode = Episode.new("Test goal")
      {:ok, episode} = Episode.close(episode)

      assert {:error, %EpisodeError{reason: :episode_closed}} =
               Episode.append(episode, "obs", "act", @default_opts)
    end

    test "accepts config option and resolves per-step opts" do
      stub_embedding()

      Mnemosyne.MockLLM
      |> stub(:chat, fn _messages, opts ->
        assert Keyword.get(opts, :model) == "test:model"
        {:ok, %LLM.Response{content: "subgoal", model: "mock:test", usage: %{}}}
      end)

      episode = Episode.new("Test goal")
      opts = @default_opts ++ [config: @test_config]

      assert {:ok, _episode, _trace} =
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

  describe "score_pending_reward/2" do
    test "scores the last step with sentinel" do
      stub_subgoal_only()
      episode = Episode.new("Test goal")
      {:ok, episode, _} = Episode.append(episode, "saw something", "did something", @default_opts)

      assert hd(episode.steps).reward == nil

      stub_llm_responses(["0.7"])
      assert {:ok, episode} = Episode.score_pending_reward(episode, @default_opts)
      assert hd(episode.steps).reward == 0.7
    end

    test "is no-op for empty episode" do
      episode = Episode.new("Test goal")
      assert {:ok, ^episode} = Episode.score_pending_reward(episode, @default_opts)
    end

    test "is no-op when reward already scored" do
      stub_subgoal_only()
      episode = Episode.new("Test goal")
      {:ok, episode, _} = Episode.append(episode, "obs", "act", @default_opts)

      # Manually set reward
      [step] = episode.steps
      episode = %{episode | steps: [%{step | reward: 0.9}]}

      assert {:ok, scored} = Episode.score_pending_reward(episode, @default_opts)
      assert hd(scored.steps).reward == 0.9
    end

    test "falls back to 0.5 on LLM error" do
      stub_subgoal_only()
      episode = Episode.new("Test goal")
      {:ok, episode, _} = Episode.append(episode, "obs", "act", @default_opts)

      Mnemosyne.MockLLM
      |> stub(:chat, fn _messages, _opts -> {:error, :llm_failure} end)

      assert {:ok, episode} = Episode.score_pending_reward(episode, @default_opts)
      assert hd(episode.steps).reward == 0.5
    end

    test "rejects on closed episode" do
      episode = Episode.new("Test goal")
      {:ok, closed} = Episode.close(episode)

      assert {:error, %EpisodeError{reason: :episode_closed}} =
               Episode.score_pending_reward(closed, @default_opts)
    end
  end

  describe "build_trajectory_from_steps/1" do
    test "raises on empty list" do
      assert_raise ArgumentError, "cannot build trajectory from empty steps", fn ->
        Episode.build_trajectory_from_steps([])
      end
    end

    test "builds trajectory from a single step" do
      step = %{
        index: 0,
        observation: "obs",
        action: "act",
        subgoal: "do thing",
        state: "state",
        reward: 0.5,
        embedding: [0.1, 0.2],
        trajectory_id: "traj_abc"
      }

      traj = Episode.build_trajectory_from_steps([step])

      assert traj.id == "traj_abc"
      assert traj.steps == [step]
      assert traj.subgoal == "do thing"
    end

    test "sorts steps by index and uses last step's subgoal" do
      step1 = %{
        index: 2,
        observation: "obs2",
        action: "act2",
        subgoal: "second goal",
        state: "state2",
        reward: 0.7,
        embedding: [0.3, 0.4],
        trajectory_id: "traj_xyz"
      }

      step0 = %{
        index: 0,
        observation: "obs0",
        action: "act0",
        subgoal: "first goal",
        state: "state0",
        reward: 0.3,
        embedding: [0.1, 0.2],
        trajectory_id: "traj_xyz"
      }

      step_mid = %{
        index: 1,
        observation: "obs1",
        action: "act1",
        subgoal: "mid goal",
        state: "state1",
        reward: 0.5,
        embedding: [0.2, 0.3],
        trajectory_id: "traj_xyz"
      }

      traj = Episode.build_trajectory_from_steps([step1, step0, step_mid])

      assert traj.id == "traj_xyz"
      assert [%{index: 0}, %{index: 1}, %{index: 2}] = traj.steps
      assert traj.subgoal == "second goal"
    end
  end

  describe "close/1" do
    test "closes episode and builds trajectories" do
      stub_subgoal_only()
      episode = Episode.new("Test goal")
      {:ok, episode, _trace} = Episode.append(episode, "obs1", "act1", @default_opts)

      # Second append: subgoal + reward for step 0
      stub_llm_responses(["Same subgoal", "0.9"])
      stub_embedding()
      {:ok, episode, _trace} = Episode.append(episode, "obs2", "act2", @default_opts)

      # Score last pending step before close
      stub_llm_responses(["0.8"])
      {:ok, episode} = Episode.score_pending_reward(episode, @default_opts)

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

      assert {:error, %EpisodeError{reason: :already_closed}} = Episode.close(closed)
    end
  end
end
