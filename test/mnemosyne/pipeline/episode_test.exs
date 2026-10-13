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

  @raw_steps [
    %{observation: "saw something", action: "did something"},
    %{observation: "result appeared", action: "clicked it"}
  ]

  defp user_content(messages), do: Enum.find(messages, &(&1.role == :user)).content
  defp system_content(messages), do: Enum.find(messages, &(&1.role == :system)).content

  # State responses echo the observation so step order can be asserted; reward
  # responses are looked up by the step's action.
  defp stub_llm(opts \\ []) do
    rewards = Keyword.get(opts, :rewards, %{})
    subgoals = Keyword.get(opts, :subgoals, %{})

    Mnemosyne.MockLLM
    |> stub(:chat, fn messages, _opts ->
      user = user_content(messages)

      content =
        if system_content(messages) =~ "evaluating agent performance",
          do: by_action(rewards, user, "0.5"),
          else: "state after: " <> (Regex.run(~r/Observation: (.*)/, user) |> Enum.at(1))

      {:ok, %LLM.Response{content: content, model: "mock:test", usage: %{}}}
    end)
    |> stub(:chat_structured, fn messages, _schema, _opts ->
      subgoal = by_action(subgoals, user_content(messages), "default subgoal")

      {:ok,
       %LLM.Response{content: %{reasoning: "r", subgoal: subgoal}, model: "mock:test", usage: %{}}}
    end)
  end

  defp by_action(responses, user, default) do
    Enum.find_value(responses, default, fn {action, response} ->
      if user =~ action, do: response
    end)
  end

  defp stub_embedding(vectors_by_subgoal \\ %{}) do
    Mnemosyne.MockEmbedding
    |> stub(:embed_batch, fn texts, _opts ->
      vectors = Enum.map(texts, &Map.get(vectors_by_subgoal, &1, List.duplicate(0.1, 128)))
      {:ok, %Embedding.Response{vectors: vectors, model: "mock:embed", usage: %{}}}
    end)
  end

  describe "new/1" do
    test "creates episode with goal and empty state" do
      episode = Episode.new("Find the answer")

      assert episode.goal == "Find the answer"
      assert episode.steps == []
      assert episode.trajectories == []
      assert episode.closed == false
      assert String.starts_with?(episode.id, "ep_")
    end
  end

  describe "new/2" do
    test "uses an explicit episode ID" do
      episode = Episode.new("Find the answer", id: "task-42")

      assert episode.id == "task-42"
    end
  end

  describe "standardize/3" do
    test "derives state, subgoal, reward and embedding for every step in order" do
      stub_llm(
        rewards: %{"did something" => "0.8", "clicked it" => "0.3"},
        subgoals: %{"did something" => "Navigate to config", "clicked it" => "Explore options"}
      )

      stub_embedding()

      assert {:ok, episode} =
               Episode.standardize(Episode.new("Test goal"), @raw_steps, @default_opts)

      assert episode.closed
      assert [step_0, step_1] = episode.steps

      assert %{
               index: 0,
               observation: "saw something",
               action: "did something",
               subgoal: "Navigate to config",
               state: "state after: saw something",
               reward: 0.8
             } = step_0

      assert %{
               index: 1,
               observation: "result appeared",
               action: "clicked it",
               subgoal: "Explore options",
               state: "state after: result appeared",
               reward: 0.3
             } = step_1

      assert is_list(step_0.embedding) and is_list(step_1.embedding)
      assert step_0.trajectory_id == step_1.trajectory_id
      assert [%{steps: [_, _]}] = episode.trajectories
    end

    test "chains state derivation and scores rewards against the next observation" do
      stub_llm()
      stub_embedding()
      test_pid = self()

      Mnemosyne.MockLLM
      |> stub(:chat, fn messages, _opts ->
        send(test_pid, {:chat, system_content(messages), user_content(messages)})
        {:ok, %LLM.Response{content: "0.5", model: "mock:test", usage: %{}}}
      end)

      assert {:ok, _} = Episode.standardize(Episode.new("Test goal"), @raw_steps, @default_opts)

      assert_received {:chat, first_state_system, first_state_user}
      assert first_state_system =~ "initial observation"
      assert first_state_user =~ "saw something"
      refute first_state_user =~ "did something"

      assert_received {:chat, _, second_state_user}
      assert second_state_user =~ "Previous state: 0.5"
      assert second_state_user =~ "Action: did something"
      assert second_state_user =~ "Observation: result appeared"

      rewards =
        for _ <- 1..2 do
          assert_received {:chat, system, user}
          assert system =~ "evaluating agent performance"
          user
        end

      assert Enum.any?(rewards, &(&1 =~ "Observation (at time t + 1): result appeared"))
      assert Enum.any?(rewards, &(&1 =~ "[Episode ended - no further observation]"))
    end

    test "starts a new trajectory when adjacent subgoals diverge" do
      stub_llm(subgoals: %{"did something" => "first", "clicked it" => "second"})
      stub_embedding(%{"first" => [1.0, 0.0], "second" => [0.0, 1.0]})

      assert {:ok, episode} =
               Episode.standardize(Episode.new("Test goal"), @raw_steps, @default_opts)

      assert [step_0, step_1] = episode.steps
      refute step_0.trajectory_id == step_1.trajectory_id
      assert [%{subgoal: "first"}, %{subgoal: "second"}] = episode.trajectories
    end

    test "falls back to 0.5 when reward scoring fails" do
      stub_llm()
      stub_embedding()

      Mnemosyne.MockLLM
      |> stub(:chat, fn messages, _opts ->
        if system_content(messages) =~ "evaluating agent performance",
          do: {:error, :llm_failure},
          else: {:ok, %LLM.Response{content: "state", model: "mock:test", usage: %{}}}
      end)

      assert {:ok, episode} =
               Episode.standardize(Episode.new("Test goal"), @raw_steps, @default_opts)

      assert Enum.map(episode.steps, & &1.reward) == [0.5, 0.5]
    end

    test "rejects a closed episode" do
      {:ok, closed} = Episode.close(Episode.new("Test goal"))

      assert {:error, %EpisodeError{reason: :episode_closed}} =
               Episode.standardize(closed, @raw_steps, @default_opts)
    end

    test "accepts config option and resolves per-step opts" do
      stub_embedding()

      Mnemosyne.MockLLM
      |> stub(:chat, fn _messages, opts ->
        assert Keyword.get(opts, :model) == "test:model"
        {:ok, %LLM.Response{content: "derived state", model: "mock:test", usage: %{}}}
      end)
      |> stub(:chat_structured, fn _messages, _schema, opts ->
        assert Keyword.get(opts, :model) == "test:model"

        {:ok,
         %LLM.Response{
           content: %{reasoning: "r", subgoal: "subgoal"},
           model: "mock:test",
           usage: %{}
         }}
      end)

      opts = @default_opts ++ [config: @test_config]

      assert {:ok, _episode} = Episode.standardize(Episode.new("Test goal"), @raw_steps, opts)
    end

    test "propagates LLM errors from state derivation" do
      Mnemosyne.MockLLM
      |> stub(:chat, fn _messages, _opts -> {:error, :llm_failure} end)

      assert {:error, :llm_failure} =
               Episode.standardize(Episode.new("Test goal"), @raw_steps, @default_opts)
    end

    test "propagates LLM errors from subgoal inference" do
      stub_llm()

      Mnemosyne.MockLLM
      |> stub(:chat_structured, fn _messages, _schema, _opts -> {:error, :llm_failure} end)

      assert {:error, :llm_failure} =
               Episode.standardize(Episode.new("Test goal"), @raw_steps, @default_opts)
    end

    test "propagates embedding errors" do
      stub_llm()

      Mnemosyne.MockEmbedding
      |> stub(:embed_batch, fn _texts, _opts -> {:error, :embed_failure} end)

      assert {:error, :embed_failure} =
               Episode.standardize(Episode.new("Test goal"), @raw_steps, @default_opts)
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
    test "closes episode and groups steps into trajectories" do
      step = fn index, trajectory_id ->
        %{
          index: index,
          observation: "obs#{index}",
          action: "act#{index}",
          subgoal: "subgoal#{index}",
          state: "state#{index}",
          reward: 0.5,
          embedding: [0.1],
          trajectory_id: trajectory_id
        }
      end

      episode = %{
        Episode.new("Test goal")
        | steps: [step.(0, "traj_a"), step.(1, "traj_a"), step.(2, "traj_b")]
      }

      {:ok, closed} = Episode.close(episode)

      assert closed.closed == true

      assert [%{id: "traj_a", subgoal: "subgoal1"}, %{id: "traj_b", subgoal: "subgoal2"}] =
               closed.trajectories
    end

    test "rejects double close" do
      episode = Episode.new("Test goal")
      {:ok, closed} = Episode.close(episode)

      assert {:error, %EpisodeError{reason: :already_closed}} = Episode.close(closed)
    end
  end
end
