defmodule Mnemosyne.Pipeline.Episode do
  @moduledoc """
  Standardizes a complete observation-action trajectory into an episode.

  Steps are annotated in windows: one LLM call derives the state
  `s_t = f(s_{t-1}, a_{t-1}, o_t)` and the subgoal `g_t = f(s_t, o_t, a_t)` for
  every step of a window, and the last state is carried into the next window.
  A window holds up to #{8} steps and is cut earlier when its text grows large.

  Rewards `r_t = f(a_t, g_t, o_{t+1})` are then scored for all steps
  concurrently. With `Config.decision` set, one decision request per window
  scores the rewards and each step's salience (the probability that it holds
  information worth remembering, used to gate fact extraction); otherwise
  each step gets its own reward prompt and no salience. Finally every subgoal
  is embedded in one batch and the steps are segmented into trajectories where
  adjacent subgoal similarity drops below `Config.segmentation_threshold`.
  """
  require Logger

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.Errors.Invalid.EpisodeError
  alias Mnemosyne.Errors.Invalid.PromptError
  alias Mnemosyne.Graph.Similarity
  alias Mnemosyne.ModelCall
  alias Mnemosyne.Pipeline.Prompts.AnnotateSteps
  alias Mnemosyne.Pipeline.Prompts.GetReward
  alias Mnemosyne.Telemetry
  alias Mnemosyne.Trajectory

  @default_segmentation_threshold 0.75
  @step_timeout :timer.seconds(60)
  @final_observation "[Episode ended - no further observation]"
  @fallback_reward 0.5
  @window_steps 8
  @window_chars 24_000

  @enforce_keys [:id, :goal]
  defstruct [:id, :goal, :occurred_at, steps: [], trajectories: [], closed: false]

  @type t :: %__MODULE__{
          id: String.t(),
          goal: String.t(),
          occurred_at: DateTime.t() | nil,
          steps: [step()],
          trajectories: [trajectory()],
          closed: boolean()
        }

  @typedoc "A single standardized observation-action step within an episode"
  @type step :: %{
          index: non_neg_integer(),
          observation: String.t(),
          action: String.t(),
          subgoal: String.t(),
          state: String.t() | nil,
          reward: float() | nil,
          salience: float() | nil,
          embedding: [float()] | nil,
          trajectory_id: String.t()
        }

  @typedoc "A completed trajectory segment"
  @type trajectory :: %{
          required(:id) => String.t(),
          required(:steps) => [step()],
          required(:subgoal) => String.t(),
          optional(:occurred_at) => DateTime.t() | nil
        }

  @doc "Creates a new open episode targeting the given goal."
  @spec new(String.t(), keyword()) :: t()
  def new(goal, opts \\ []) do
    %__MODULE__{
      id: Keyword.get_lazy(opts, :id, fn -> generate_id("ep") end),
      goal: goal,
      occurred_at: Keyword.get(opts, :occurred_at)
    }
  end

  @doc """
  Standardizes raw observation-action steps into a closed episode with
  states, subgoals, rewards, subgoal embeddings, and trajectory segments.
  """
  @spec standardize(t(), [Trajectory.step()], keyword()) ::
          {:ok, t()} | {:error, Mnemosyne.Errors.error()}
  def standardize(%__MODULE__{closed: true}, _raw_steps, _opts),
    do: {:error, EpisodeError.exception(reason: :episode_closed)}

  def standardize(%__MODULE__{} = episode, raw_steps, opts) do
    Telemetry.span(
      [:episode, :standardize],
      %{
        episode_id: episode.id,
        repo_id: Keyword.get(opts, :repo_id),
        source_id: Keyword.get(opts, :source_id)
      },
      fn ->
        ctx = %{
          goal: episode.goal,
          occurred_at: episode.occurred_at,
          llm: Keyword.fetch!(opts, :llm),
          embedding: Keyword.fetch!(opts, :embedding),
          llm_opts: Keyword.get(opts, :llm_opts, []),
          config: Keyword.get(opts, :config),
          model_context: Keyword.get(opts, :model_context)
        }

        with {:ok, steps} <- annotate_steps(raw_steps, ctx),
             steps = score_steps(steps, ctx),
             {:ok, steps} <- embed_subgoals(steps, ctx),
             {:ok, closed} <- close(%{episode | steps: segment(steps, threshold(ctx.config))}) do
          {{:ok, closed},
           %{step_count: length(closed.steps), trajectory_count: length(closed.trajectories)}}
        else
          error -> {error, %{}}
        end
      end
    )
  end

  @doc "Closes the episode, grouping steps into trajectory segments."
  @spec close(t()) :: {:ok, t()} | {:error, EpisodeError.t()}
  def close(%__MODULE__{closed: true}),
    do: {:error, EpisodeError.exception(reason: :already_closed)}

  def close(%__MODULE__{} = episode) do
    trajectories = build_trajectories(episode)
    {:ok, %{episode | closed: true, trajectories: trajectories}}
  end

  @doc "Builds a trajectory struct from a list of steps sharing the same trajectory_id."
  @spec build_trajectory_from_steps([step()]) :: trajectory()
  def build_trajectory_from_steps([]) do
    raise ArgumentError, "cannot build trajectory from empty steps"
  end

  def build_trajectory_from_steps(steps) do
    sorted = Enum.sort_by(steps, & &1.index)

    %{
      id: hd(sorted).trajectory_id,
      steps: sorted,
      subgoal: List.last(sorted).subgoal
    }
  end

  defp annotate_steps(raw_steps, ctx) do
    raw_steps
    |> Enum.with_index(fn raw, index ->
      %{
        index: index,
        observation: raw.observation,
        action: raw.action,
        subgoal: nil,
        state: nil,
        reward: nil,
        salience: nil,
        embedding: nil,
        trajectory_id: nil
      }
    end)
    |> windows()
    |> Enum.reduce_while({:ok, []}, fn window, {:ok, annotated} ->
      case annotate_window(ctx, window, List.last(annotated)) do
        {:ok, steps} -> {:cont, {:ok, annotated ++ steps}}
        error -> {:halt, error}
      end
    end)
  end

  # Cuts steps into windows of at most @window_steps steps and about
  # @window_chars characters, so one oversized step cannot crowd a request.
  defp windows(steps) do
    Enum.chunk_while(
      steps,
      {[], 0},
      fn step, {window, size} ->
        step_size = String.length(step.observation) + String.length(step.action)

        if window != [] and
             (length(window) == @window_steps or size + step_size > @window_chars),
           do: {:cont, Enum.reverse(window), {[step], step_size}},
           else: {:cont, {[step | window], size + step_size}}
      end,
      fn
        {[], _size} -> {:cont, nil}
        {window, _size} -> {:cont, Enum.reverse(window), nil}
      end
    )
  end

  # A model that skips a step gets the window again in two halves, down to
  # single steps, before the ingestion fails.
  defp annotate_window(ctx, window, previous) do
    case request_annotations(ctx, window, previous) do
      {:ok, annotations} ->
        {:ok, Enum.zip_with(window, annotations, &Map.merge/2)}

      {:error, %PromptError{reason: :incomplete_steps}} when length(window) > 1 ->
        {first, second} = Enum.split(window, div(length(window), 2))

        with {:ok, first} <- annotate_window(ctx, first, previous),
             {:ok, second} <- annotate_window(ctx, second, List.last(first)) do
          {:ok, first ++ second}
        end

      error ->
        error
    end
  end

  defp request_annotations(ctx, window, previous) do
    messages =
      AnnotateSteps.build_messages(%{
        steps:
          Enum.map(
            window,
            &%{number: &1.index + 1, observation: &1.observation, action: &1.action}
          ),
        goal: ctx.goal,
        occurred_at: ctx.occurred_at,
        previous: previous,
        overlay: Config.resolve_overlay(ctx.config, :annotate_steps)
      })

    with {:ok, %{content: content}} <-
           ModelCall.chat_structured(
             ctx.model_context,
             ctx.llm,
             :annotate_steps,
             messages,
             AnnotateSteps.schema(),
             Config.llm_opts(ctx.config, :annotate_steps, ctx.llm_opts)
           ) do
      AnnotateSteps.parse_response(content, Enum.map(window, &(&1.index + 1)))
    end
  end

  defp score_steps(steps, ctx) do
    observations = Map.new(steps, &{&1.index, &1.observation})
    next_observation = &Map.get(observations, &1.index + 1, @final_observation)

    case Config.decision_opts(ctx.config) do
      nil ->
        steps
        |> Task.async_stream(
          &%{&1 | reward: evaluate_reward(ctx, &1, next_observation.(&1))},
          timeout: @step_timeout
        )
        |> Enum.map(fn {:ok, step} -> step end)

      opts ->
        steps
        |> windows()
        |> Task.async_stream(
          &judge_window(ctx, &1, next_observation.(List.last(&1)), opts),
          timeout: @step_timeout
        )
        |> Enum.flat_map(fn {:ok, window} -> window end)
    end
  end

  # One decision request scores, for every step of the window, whether its
  # action served its subgoal and whether it is worth remembering.
  defp judge_window(ctx, steps, next_observation, opts) do
    last = List.last(steps)
    overlay = Config.resolve_overlay(ctx.config, :get_reward)

    state = %{
      goal: ctx.goal,
      steps:
        Enum.map(steps, fn step ->
          %{
            step: step.index + 1,
            observation: step.observation,
            action: step.action,
            subgoal: step.subgoal
          }
        end),
      next_observation: next_observation
    }

    questions =
      Enum.reduce(steps, %{}, fn step, acc ->
        number = step.index + 1

        outcome =
          if step == last, do: "next_observation", else: "the observation in step #{number + 1}"

        reward =
          "Did the action in step #{number} serve the subgoal of that step, " <>
            "judging by #{outcome}?" <> if overlay, do: "\n\n#{overlay}", else: ""

        memorable =
          "Does step #{number} contain facts, decisions, preferences or outcomes " <>
            "worth remembering after this task ends?"

        acc |> Map.put("reward_#{number}", reward) |> Map.put("memorable_#{number}", memorable)
      end)

    probabilities =
      case ModelCall.evaluate(ctx.model_context, ctx.llm, :get_reward, state, questions, opts) do
        {:ok, %{content: probabilities}} ->
          probabilities

        {:error, reason} ->
          Logger.warning(
            "decision scoring failed, using fallback reward #{@fallback_reward}: #{inspect(reason)}"
          )

          %{}
      end

    Enum.map(steps, fn step ->
      number = step.index + 1

      %{
        step
        | reward: Map.get(probabilities, "reward_#{number}", @fallback_reward) / 1,
          salience: probabilities["memorable_#{number}"]
      }
    end)
  end

  defp embed_subgoals(steps, ctx) do
    with {:ok, %Embedding.Response{vectors: vectors}} <-
           ModelCall.embed_batch(
             ctx.model_context,
             ctx.embedding,
             :get_subgoal,
             Enum.map(steps, & &1.subgoal),
             Config.embedding_opts(ctx.config)
           ) do
      {:ok, Enum.zip_with(steps, vectors, &%{&1 | embedding: &2})}
    end
  end

  defp threshold(%Config{segmentation_threshold: threshold}), do: threshold
  defp threshold(nil), do: @default_segmentation_threshold

  defp segment(steps, threshold) do
    {segmented, _} =
      Enum.map_reduce(steps, {generate_id("traj"), nil}, fn step, {trajectory_id, previous} ->
        trajectory_id =
          if boundary?(previous, step.embedding, threshold),
            do: generate_id("traj"),
            else: trajectory_id

        {%{step | trajectory_id: trajectory_id}, {trajectory_id, step.embedding}}
      end)

    segmented
  end

  defp boundary?(nil, _embedding, _threshold), do: false

  defp boundary?(previous, embedding, threshold) do
    similarity = Similarity.cosine_similarity(previous, embedding)

    if similarity < threshold do
      Logger.debug(
        "trajectory boundary detected (similarity=#{similarity} threshold=#{threshold})"
      )

      true
    else
      false
    end
  end

  defp evaluate_reward(ctx, step, next_observation) do
    messages =
      GetReward.build_messages(%{
        state: step.state,
        action: step.action,
        subgoal: step.subgoal,
        next_observation: next_observation,
        overlay: Config.resolve_overlay(ctx.config, :get_reward)
      })

    with {:ok, %{content: content}} <-
           ModelCall.chat(
             ctx.model_context,
             ctx.llm,
             :get_reward,
             messages,
             Config.llm_opts(ctx.config, :get_reward, ctx.llm_opts)
           ),
         {:ok, reward} <- GetReward.parse_response(content) do
      reward
    else
      {:error, reason} ->
        Logger.warning(
          "reward scoring failed, using fallback #{@fallback_reward}: #{inspect(reason)}"
        )

        @fallback_reward
    end
  end

  defp build_trajectories(episode) do
    episode.steps
    |> Enum.group_by(& &1.trajectory_id)
    |> Enum.map(fn {_traj_id, steps} ->
      steps |> build_trajectory_from_steps() |> Map.put(:occurred_at, episode.occurred_at)
    end)
    |> Enum.sort_by(fn traj -> hd(traj.steps).index end)
  end

  defp generate_id(prefix) do
    "#{prefix}_#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"
  end
end
