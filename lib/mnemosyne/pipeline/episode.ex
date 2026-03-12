defmodule Mnemosyne.Pipeline.Episode do
  @moduledoc """
  Functional core for managing in-progress episodes.

  An episode tracks a sequence of observation-action steps organized
  into trajectories. Trajectory boundaries are detected when subgoal
  embedding similarity drops below a threshold.
  """
  use TypedStruct

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.Graph.Similarity
  alias Mnemosyne.Pipeline.Prompts.GetReward
  alias Mnemosyne.Pipeline.Prompts.GetState
  alias Mnemosyne.Pipeline.Prompts.GetSubgoal

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
          {:ok, t()} | {:error, term()}
  def append(%__MODULE__{closed: true}, _observation, _action, _opts),
    do: {:error, :episode_closed}

  def append(%__MODULE__{} = episode, observation, action, opts) do
    llm = Keyword.fetch!(opts, :llm)
    embedding = Keyword.fetch!(opts, :embedding)
    llm_opts = Keyword.get(opts, :llm_opts, [])
    config = Keyword.get(opts, :config)

    with {:ok, subgoal} <- infer_subgoal(llm, observation, action, episode.goal, config, llm_opts),
         {:ok, %Embedding.Response{vectors: [subgoal_embedding | _]}} <-
           embedding.embed(subgoal, resolve_emb_opts(config)),
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

      episode = maybe_segment_trajectory(episode, subgoal_embedding)
      step = %{step | trajectory_id: episode.current_trajectory_id}

      {:ok,
       %{episode | steps: episode.steps ++ [step], current_subgoal_embedding: subgoal_embedding}}
    end
  end

  @doc "Closes the episode, grouping steps into trajectory segments."
  @spec close(t()) :: {:ok, t()} | {:error, term()}
  def close(%__MODULE__{closed: true}), do: {:error, :already_closed}

  def close(%__MODULE__{} = episode) do
    trajectories = build_trajectories(episode)
    {:ok, %{episode | closed: true, trajectories: trajectories}}
  end

  defp infer_subgoal(llm, observation, action, goal, config, llm_opts) do
    messages = GetSubgoal.build_messages(%{observation: observation, action: action, goal: goal})

    with {:ok, %{content: content}} <-
           llm.chat(messages, resolve_llm_opts(config, :get_subgoal, llm_opts)) do
      GetSubgoal.parse_response(content)
    end
  end

  defp evaluate_reward(llm, observation, action, subgoal, config, llm_opts) do
    messages =
      GetReward.build_messages(%{observation: observation, action: action, subgoal: subgoal})

    with {:ok, %{content: content}} <-
           llm.chat(messages, resolve_llm_opts(config, :get_reward, llm_opts)) do
      GetReward.parse_response(content)
    end
  end

  defp summarize_state(llm, episode, config, llm_opts) do
    messages = GetState.build_messages(%{trajectory: episode.steps, goal: episode.goal})

    with {:ok, %{content: content}} <-
           llm.chat(messages, resolve_llm_opts(config, :get_state, llm_opts)) do
      GetState.parse_response(content)
    end
  end

  defp resolve_llm_opts(nil, _step, base_opts), do: base_opts

  defp resolve_llm_opts(config, step, base_opts) do
    resolved = Config.resolve(config, step)
    [model: resolved.model] ++ Map.to_list(resolved.opts) ++ base_opts
  end

  defp resolve_emb_opts(nil), do: []

  defp resolve_emb_opts(config) do
    resolved = Config.resolve_embedding(config)
    [model: resolved.model] ++ Map.to_list(resolved.opts)
  end

  defp maybe_segment_trajectory(%{current_subgoal_embedding: nil} = episode, _new_embedding),
    do: episode

  defp maybe_segment_trajectory(episode, new_embedding) do
    similarity = Similarity.cosine_similarity(episode.current_subgoal_embedding, new_embedding)

    if similarity < @trajectory_similarity_threshold do
      %{episode | current_trajectory_id: generate_id("traj")}
    else
      episode
    end
  end

  defp build_trajectories(episode) do
    episode.steps
    |> Enum.group_by(& &1.trajectory_id)
    |> Enum.map(fn {traj_id, steps} ->
      sorted_steps = Enum.sort_by(steps, & &1.index)
      subgoal = List.last(sorted_steps).subgoal

      %{id: traj_id, steps: sorted_steps, subgoal: subgoal}
    end)
    |> Enum.sort_by(fn traj -> hd(traj.steps).index end)
  end

  defp generate_id(prefix) do
    "#{prefix}_#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"
  end
end
