defmodule Mnemosyne.Pipeline.Episode do
  @moduledoc """
  Functional core for managing in-progress episodes.

  An episode tracks a sequence of observation-action steps organized
  into trajectories. Trajectory boundaries are detected when subgoal
  embedding similarity drops below a threshold.
  """
  use TypedStruct

  require Logger

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.Errors.Invalid.EpisodeError
  alias Mnemosyne.Graph.Similarity
  alias Mnemosyne.Notifier.Trace.Episode, as: EpisodeTrace
  alias Mnemosyne.Pipeline.Prompts.GetReward
  alias Mnemosyne.Pipeline.Prompts.GetState
  alias Mnemosyne.Pipeline.Prompts.GetSubgoal
  alias Mnemosyne.Telemetry

  @trajectory_similarity_threshold 0.75

  typedstruct do
    field :id, String.t(), enforce: true
    field :goal, String.t(), enforce: true
    field :steps, [step()], default: []
    field :trajectories, [trajectory()], default: []
    field :current_trajectory_id, String.t(), default: nil
    field :current_subgoal_embedding, [float()] | nil, default: nil
    field :closed, boolean(), default: false
  end

  @typedoc "A single observation-action step within an episode"
  @type step :: %{
          index: non_neg_integer(),
          observation: String.t(),
          action: String.t(),
          subgoal: String.t(),
          state: String.t(),
          reward: float(),
          embedding: [float()] | nil,
          trajectory_id: String.t()
        }

  @typedoc "A completed trajectory segment"
  @type trajectory :: %{
          id: String.t(),
          steps: [step()],
          subgoal: String.t()
        }

  @doc "Creates a new open episode targeting the given goal."
  @spec new(String.t()) :: t()
  def new(goal) do
    %__MODULE__{
      id: generate_id("ep"),
      goal: goal,
      current_trajectory_id: generate_id("traj")
    }
  end

  @doc "Appends an observation-action step, inferring subgoal, reward, and state via LLM."
  @spec append(t(), String.t(), String.t(), keyword()) ::
          {:ok, t(), EpisodeTrace.t()} | {:error, Mnemosyne.Errors.error()}
  def append(%__MODULE__{closed: true}, _observation, _action, _opts),
    do: {:error, EpisodeError.exception(reason: :episode_closed)}

  def append(%__MODULE__{} = episode, observation, action, opts) do
    Telemetry.span(
      [:episode, :append],
      %{
        episode_id: episode.id,
        repo_id: Keyword.get(opts, :repo_id),
        session_id: Keyword.get(opts, :session_id)
      },
      fn ->
        llm = Keyword.fetch!(opts, :llm)
        embedding = Keyword.fetch!(opts, :embedding)
        llm_opts = Keyword.get(opts, :llm_opts, [])
        config = Keyword.get(opts, :config)
        verbosity = if config, do: config.trace_verbosity, else: :summary
        start_time = System.monotonic_time(:microsecond)

        with {:ok, subgoal} <-
               infer_subgoal(llm, observation, action, episode.goal, config, llm_opts),
             {:ok, %Embedding.Response{vectors: [subgoal_embedding | _]}} <-
               embedding.embed(subgoal, Config.embedding_opts(config)),
             {:ok, reward} <- evaluate_reward(llm, observation, action, subgoal, config, llm_opts),
             {:ok, state} <- summarize_state(llm, episode, config, llm_opts) do
          step = %{
            index: length(episode.steps),
            observation: observation,
            action: action,
            subgoal: subgoal,
            state: state,
            reward: reward,
            embedding: subgoal_embedding,
            trajectory_id: episode.current_trajectory_id
          }

          prev_trajectory_id = episode.current_trajectory_id
          {episode, similarity} = maybe_segment_trajectory(episode, subgoal_embedding)
          step = %{step | trajectory_id: episode.current_trajectory_id}

          updated =
            %{
              episode
              | steps: episode.steps ++ [step],
                current_subgoal_embedding: subgoal_embedding
            }

          new_trajectory = updated.current_trajectory_id != prev_trajectory_id
          duration_us = System.monotonic_time(:microsecond) - start_time

          trace = %EpisodeTrace{
            verbosity: verbosity,
            step_index: step.index,
            trajectory_id: step.trajectory_id,
            boundary_detected: new_trajectory,
            reward: reward,
            duration_us: duration_us,
            subgoal: if(verbosity == :detailed, do: subgoal),
            similarity_score: if(verbosity == :detailed, do: similarity),
            similarity_threshold:
              if(verbosity == :detailed, do: @trajectory_similarity_threshold),
            state_summary: if(verbosity == :detailed, do: state)
          }

          {{:ok, updated, trace},
           %{step_count: length(updated.steps), new_trajectory: new_trajectory}}
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

  defp infer_subgoal(llm, observation, action, goal, config, llm_opts) do
    messages = GetSubgoal.build_messages(%{observation: observation, action: action, goal: goal})

    with {:ok, %{content: content}} <-
           llm.chat(messages, Config.llm_opts(config, :get_subgoal, llm_opts)) do
      GetSubgoal.parse_response(content)
    end
  end

  defp evaluate_reward(llm, observation, action, subgoal, config, llm_opts) do
    messages =
      GetReward.build_messages(%{observation: observation, action: action, subgoal: subgoal})

    with {:ok, %{content: content}} <-
           llm.chat(messages, Config.llm_opts(config, :get_reward, llm_opts)) do
      GetReward.parse_response(content)
    end
  end

  defp summarize_state(llm, episode, config, llm_opts) do
    messages = GetState.build_messages(%{trajectory: episode.steps, goal: episode.goal})

    with {:ok, %{content: content}} <-
           llm.chat(messages, Config.llm_opts(config, :get_state, llm_opts)) do
      GetState.parse_response(content)
    end
  end

  defp maybe_segment_trajectory(%{current_subgoal_embedding: nil} = episode, _new_embedding),
    do: {episode, nil}

  defp maybe_segment_trajectory(episode, new_embedding) do
    similarity = Similarity.cosine_similarity(episode.current_subgoal_embedding, new_embedding)

    if similarity < @trajectory_similarity_threshold do
      Logger.debug(
        "trajectory boundary detected (similarity=#{similarity} threshold=#{@trajectory_similarity_threshold})"
      )

      {%{episode | current_trajectory_id: generate_id("traj")}, similarity}
    else
      {episode, similarity}
    end
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

  defp build_trajectories(episode) do
    episode.steps
    |> Enum.group_by(& &1.trajectory_id)
    |> Enum.map(fn {_traj_id, steps} -> build_trajectory_from_steps(steps) end)
    |> Enum.sort_by(fn traj -> hd(traj.steps).index end)
  end

  defp generate_id(prefix) do
    "#{prefix}_#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"
  end
end
