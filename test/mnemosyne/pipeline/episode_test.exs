defmodule Mnemosyne.Pipeline.EpisodeTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.Errors.Invalid.EpisodeError
  alias Mnemosyne.Errors.Invalid.PromptError
  alias Mnemosyne.LLM
  alias Mnemosyne.Pipeline.Episode
  alias Mnemosyne.TestPrompts

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

  # Annotations echo the observation as state so step order can be asserted;
  # reward responses are looked up by the step's action.
  defp stub_llm(opts \\ []) do
    rewards = Keyword.get(opts, :rewards, %{})
    subgoals = Keyword.get(opts, :subgoals, "default subgoal")

    Mnemosyne.MockLLM
    |> stub(:chat, fn messages, _opts ->
      reward = reward_for(rewards, user_content(messages))
      {:ok, %LLM.Response{content: reward, model: "mock:test", usage: %{}}}
    end)
    |> stub(:chat_structured, fn messages, _schema, _opts ->
      annotations = TestPrompts.annotations(messages, subgoal: subgoals)
      {:ok, %LLM.Response{content: annotations, model: "mock:test", usage: %{}}}
    end)
  end

  defp reward_for(rewards, user) do
    Enum.find_value(rewards, "0.5", fn {action, reward} ->
      if user =~ "Action (at time t): #{action}", do: reward
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
               reward: 0.8,
               salience: nil
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

    test "annotates a window of steps per call and carries state into the next window" do
      stub_llm()
      stub_embedding()
      test_pid = self()

      Mnemosyne.MockLLM
      |> stub(:chat_structured, fn messages, _schema, _opts ->
        send(test_pid, {:annotate, user_content(messages)})
        annotations = TestPrompts.annotations(messages)
        {:ok, %LLM.Response{content: annotations, model: "mock:test", usage: %{}}}
      end)

      raw_steps = for n <- 1..9, do: %{observation: "obs #{n}", action: "act #{n}"}

      assert {:ok, episode} =
               Episode.standardize(Episode.new("Test goal"), raw_steps, @default_opts)

      assert Enum.map(episode.steps, & &1.state) == for(n <- 1..9, do: "state after: obs #{n}")

      assert_received {:annotate, first}
      assert first =~ "[initial state - no prior context]"
      assert first =~ "Step 1:" and first =~ "Step 8:"
      refute first =~ "Step 9:"

      assert_received {:annotate, second}
      assert second =~ "State before the first listed step: state after: obs 8"
      assert second =~ "Action taken from that state: act 8"
      assert second =~ "Step 9:"
      refute_received {:annotate, _}
    end

    test "starts a new window before the size budget is exceeded" do
      stub_llm()
      stub_embedding()
      test_pid = self()

      Mnemosyne.MockLLM
      |> stub(:chat_structured, fn messages, _schema, _opts ->
        annotations = TestPrompts.annotations(messages)
        send(test_pid, {:annotated, Enum.map(annotations.steps, & &1.step)})
        {:ok, %LLM.Response{content: annotations, model: "mock:test", usage: %{}}}
      end)

      large = String.duplicate("x", 20_000)
      raw_steps = for _ <- 1..3, do: %{observation: large, action: "act"}

      assert {:ok, _episode} =
               Episode.standardize(Episode.new("Test goal"), raw_steps, @default_opts)

      for numbers <- [[1], [2], [3]], do: assert_received({:annotated, ^numbers})
    end

    test "splits the window and retries when the model skips a step" do
      stub_llm()
      stub_embedding()
      test_pid = self()

      Mnemosyne.MockLLM
      |> stub(:chat_structured, fn messages, _schema, _opts ->
        annotations = TestPrompts.annotations(messages)
        send(test_pid, {:annotated, length(annotations.steps)})

        content =
          if length(annotations.steps) > 1,
            do: %{steps: Enum.take(annotations.steps, 1)},
            else: annotations

        {:ok, %LLM.Response{content: content, model: "mock:test", usage: %{}}}
      end)

      assert {:ok, episode} =
               Episode.standardize(Episode.new("Test goal"), @raw_steps, @default_opts)

      assert Enum.map(episode.steps, & &1.state) == [
               "state after: saw something",
               "state after: result appeared"
             ]

      for count <- [2, 1, 1], do: assert_received({:annotated, ^count})
    end

    test "fails when a single step cannot be annotated" do
      Mnemosyne.MockLLM
      |> stub(:chat_structured, fn _messages, _schema, _opts ->
        {:ok, %LLM.Response{content: %{steps: []}, model: "mock:test", usage: %{}}}
      end)

      assert {:error, %PromptError{prompt: :annotate_steps, reason: :incomplete_steps}} =
               Episode.standardize(Episode.new("Test goal"), @raw_steps, @default_opts)
    end

    test "scores rewards against the next observation" do
      stub_llm()
      stub_embedding()
      test_pid = self()

      Mnemosyne.MockLLM
      |> stub(:chat, fn messages, _opts ->
        send(test_pid, {:reward, user_content(messages)})
        {:ok, %LLM.Response{content: "0.5", model: "mock:test", usage: %{}}}
      end)

      assert {:ok, _} = Episode.standardize(Episode.new("Test goal"), @raw_steps, @default_opts)

      rewards = for _ <- 1..2, do: assert_received({:reward, user}) && user

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

    test "cuts trajectories at the configured segmentation threshold" do
      stub_llm(subgoals: %{"did something" => "first", "clicked it" => "second"})
      # cosine similarity between the two subgoal vectors is 0.5
      stub_embedding(%{"first" => [1.0, 0.0], "second" => [0.5, 0.8660254]})

      standardize = fn config ->
        {:ok, episode} =
          Episode.standardize(
            Episode.new("Test goal"),
            @raw_steps,
            @default_opts ++ [config: config]
          )

        length(episode.trajectories)
      end

      assert standardize.(@test_config) == 2
      assert standardize.(%{@test_config | segmentation_threshold: 0.3}) == 1
    end

    test "falls back to 0.5 when reward scoring fails" do
      stub_llm()
      stub_embedding()

      Mnemosyne.MockLLM
      |> stub(:chat, fn _messages, _opts -> {:error, :llm_failure} end)

      assert {:ok, episode} =
               Episode.standardize(Episode.new("Test goal"), @raw_steps, @default_opts)

      assert Enum.map(episode.steps, & &1.reward) == [0.5, 0.5]
    end

    test "rejects a closed episode" do
      {:ok, closed} = Episode.close(Episode.new("Test goal"))

      assert {:error, %EpisodeError{reason: :episode_closed}} =
               Episode.standardize(closed, @raw_steps, @default_opts)
    end

    test "resolves per-step model overrides from config" do
      stub_embedding()
      test_pid = self()

      Mnemosyne.MockLLM
      |> stub(:chat, fn _messages, opts ->
        send(test_pid, {:reward_model, Keyword.get(opts, :model)})
        {:ok, %LLM.Response{content: "0.5", model: "mock:test", usage: %{}}}
      end)
      |> stub(:chat_structured, fn messages, _schema, opts ->
        send(test_pid, {:annotate_model, Keyword.get(opts, :model)})
        annotations = TestPrompts.annotations(messages)
        {:ok, %LLM.Response{content: annotations, model: "mock:test", usage: %{}}}
      end)

      config = %{@test_config | overrides: %{annotate_steps: %{model: "test:fast"}}}
      opts = @default_opts ++ [config: config]

      assert {:ok, _episode} = Episode.standardize(Episode.new("Test goal"), @raw_steps, opts)
      assert_received {:annotate_model, "test:fast"}
      assert_received {:reward_model, "test:model"}
    end

    test "propagates LLM errors from step annotation" do
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

  describe "standardize/3 with a decision model" do
    @decision_opts @default_opts ++
                     [config: %{@test_config | decision: %{model: "test:decision", opts: %{}}}]

    test "scores reward and salience for all steps in one request" do
      stub_llm()
      stub_embedding()
      reject(&Mnemosyne.MockLLM.chat/2)

      expect(Mnemosyne.MockLLM, :evaluate, fn state, questions, opts ->
        assert opts[:model] == "test:decision"
        assert state.goal == "Test goal"
        assert state.next_observation == "[Episode ended - no further observation]"

        assert [
                 %{step: 1, observation: "saw something", action: "did something"},
                 %{step: 2, observation: "result appeared", action: "clicked it"}
               ] = state.steps

        assert Map.keys(questions) == ["memorable_1", "memorable_2", "reward_1", "reward_2"]
        assert questions["reward_1"] =~ "step 2"
        assert questions["reward_2"] =~ "next_observation"

        probabilities = %{"reward_1" => 0.9, "memorable_1" => 0.05, "memorable_2" => 0.7}
        {:ok, %LLM.Response{content: probabilities, model: "mock:decision", usage: %{}}}
      end)

      assert {:ok, episode} =
               Episode.standardize(Episode.new("Test goal"), @raw_steps, @decision_opts)

      assert [%{reward: 0.9, salience: 0.05}, %{reward: 0.5, salience: 0.7}] = episode.steps
    end

    test "falls back to neutral rewards and no salience when the request fails" do
      stub_llm()
      stub_embedding()

      expect(Mnemosyne.MockLLM, :evaluate, fn _state, _questions, _opts ->
        {:error, :unavailable}
      end)

      assert {:ok, episode} =
               Episode.standardize(Episode.new("Test goal"), @raw_steps, @decision_opts)

      assert [%{reward: 0.5, salience: nil}, %{reward: 0.5, salience: nil}] = episode.steps
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
