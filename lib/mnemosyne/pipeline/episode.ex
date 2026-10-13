defmodule Mnemosyne.Pipeline.Episode do
  @moduledoc """
  Standardizes a complete observation-action trajectory into an episode.

  For each step `t` the module derives a state `s_t = f(s_{t-1}, a_{t-1}, o_t)`
  (a sequential LLM chain), then infers subgoal `g_t = f(s_t, o_t, a_t)` and
  reward `r_t = f(s_t, a_t, g_t, o_{t+1})` for all steps concurrently, embeds
  every subgoal in one batch, and segments the steps into trajectories where
  adjacent subgoal similarity drops below a threshold.
  """
  require Logger

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.Errors.Invalid.EpisodeError
  alias Mnemosyne.Graph.Similarity
  alias Mnemosyne.ModelCall
  alias Mnemosyne.Pipeline.Prompts.GetReward
  alias Mnemosyne.Pipeline.Prompts.GetState
  alias Mnemosyne.Pipeline.Prompts.GetSubgoal
  alias Mnemosyne.Telemetry
  alias Mnemosyne.Trajectory

  @trajectory_similarity_threshold 0.75
  @step_timeout :timer.seconds(60)
  @final_observation "[Episode ended - no further observation]"
  @fallback_reward 0.5

  @enforce_keys [:id, :goal]
  defstruct [:id, :goal, steps: [], trajectories: [], closed: false]

  @type t :: %__MODULE__{
          id: String.t(),
          goal: String.t(),
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
  @spec new(String.t(), keyword()) :: t()
  def new(goal, opts \\ []) do
    %__MODULE__{id: Keyword.get_lazy(opts, :id, fn -> generate_id("ep") end), goal: goal}
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
          llm: Keyword.fetch!(opts, :llm),
          embedding: Keyword.fetch!(opts, :embedding),
          llm_opts: Keyword.get(opts, :llm_opts, []),
          config: Keyword.get(opts, :config),
          model_context: Keyword.get(opts, :model_context)
        }

        with {:ok, states} <- derive_states(raw_steps, ctx),
             {:ok, steps} <- annotate_steps(raw_steps, states, ctx),
             {:ok, steps} <- embed_subgoals(steps, ctx),
             {:ok, closed} <- close(%{episode | steps: segment(steps)}) do
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

  defp derive_states(raw_steps, ctx) do
    raw_steps
    |> Enum.zip([nil | raw_steps])
    |> Enum.reduce_while({:ok, []}, fn {step, previous}, {:ok, states} ->
      previous_action = if previous, do: previous.action

      case derive_state(ctx, List.first(states), previous_action, step.observation) do
        {:ok, state} -> {:cont, {:ok, [state | states]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, states} -> {:ok, Enum.reverse(states)}
      error -> error
    end
  end

  defp annotate_steps(raw_steps, states, ctx) do
    next_observations =
      raw_steps |> Enum.drop(1) |> Enum.map(& &1.observation) |> Kernel.++([@final_observation])

    [raw_steps, states, next_observations]
    |> Enum.zip()
    |> Enum.with_index()
    |> Task.async_stream(
      fn {{raw, state, next_observation}, index} ->
        annotate_step(ctx, index, raw, state, next_observation)
      end,
      timeout: @step_timeout
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, step}}, {:ok, steps} -> {:cont, {:ok, [step | steps]}}
      {:ok, error}, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, steps} -> {:ok, Enum.reverse(steps)}
      error -> error
    end
  end

  defp annotate_step(ctx, index, raw, state, next_observation) do
    with {:ok, subgoal} <- infer_subgoal(ctx, raw.observation, raw.action, state) do
      {:ok,
       %{
         index: index,
         observation: raw.observation,
         action: raw.action,
         subgoal: subgoal,
         state: state,
         reward: evaluate_reward(ctx, state, raw.action, subgoal, next_observation),
         embedding: nil,
         trajectory_id: nil
       }}
    end
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

  defp segment(steps) do
    {segmented, _} =
      Enum.map_reduce(steps, {generate_id("traj"), nil}, fn step, {trajectory_id, previous} ->
        trajectory_id =
          if boundary?(previous, step.embedding), do: generate_id("traj"), else: trajectory_id

        {%{step | trajectory_id: trajectory_id}, {trajectory_id, step.embedding}}
      end)

    segmented
  end

  defp boundary?(nil, _embedding), do: false

  defp boundary?(previous, embedding) do
    similarity = Similarity.cosine_similarity(previous, embedding)

    if similarity < @trajectory_similarity_threshold do
      Logger.debug(
        "trajectory boundary detected (similarity=#{similarity} threshold=#{@trajectory_similarity_threshold})"
      )

      true
    else
      false
    end
  end

  defp derive_state(ctx, previous_state, previous_action, observation) do
    messages =
      GetState.build_messages(%{
        previous_state: previous_state,
        action: previous_action,
        observation: observation,
        goal: ctx.goal,
        overlay: Config.resolve_overlay(ctx.config, :get_state)
      })

    with {:ok, %{content: content}} <-
           ModelCall.chat(
             ctx.model_context,
             ctx.llm,
             :get_state,
             messages,
             Config.llm_opts(ctx.config, :get_state, ctx.llm_opts)
           ) do
      GetState.parse_response(content)
    end
  end

  defp infer_subgoal(ctx, observation, action, state) do
    messages =
      GetSubgoal.build_messages(%{
        observation: observation,
        action: action,
        goal: ctx.goal,
        state: state,
        overlay: Config.resolve_overlay(ctx.config, :get_subgoal)
      })

    with {:ok, %{content: content}} <-
           ModelCall.chat_structured(
             ctx.model_context,
             ctx.llm,
             :get_subgoal,
             messages,
             GetSubgoal.schema(),
             Config.llm_opts(ctx.config, :get_subgoal, ctx.llm_opts)
           ) do
      GetSubgoal.parse_response(content)
    end
  end

  defp evaluate_reward(ctx, state, action, subgoal, next_observation) do
    messages =
      GetReward.build_messages(%{
        state: state,
        action: action,
        subgoal: subgoal,
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
    |> Enum.map(fn {_traj_id, steps} -> build_trajectory_from_steps(steps) end)
    |> Enum.sort_by(fn traj -> hd(traj.steps).index end)
  end

  defp generate_id(prefix) do
    "#{prefix}_#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"
  end
end
