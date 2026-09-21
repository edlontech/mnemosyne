defmodule Mnemosyne.NodeMetadata do
  @moduledoc """
  Per-node scoring metadata and caller-owned information.

  Captures access patterns, temporal information, and accumulated
  rewards to enable recency, frequency, and reward-based scoring.
  The immutable audience is inherited from the ingested trajectory; nil marks
  legacy, unclassified nodes, which are hidden in access-controlled repos.

  `custom` is an open map inherited from `Trajectory.metadata`. Mnemosyne stores
  it without using it for filtering, scoring, embeddings, or LLM prompts.
  """

  @enforce_keys [:created_at]
  defstruct [
    :created_at,
    audience: nil,
    custom: %{},
    access_count: 0,
    last_accessed_at: nil,
    cumulative_reward: 0.0,
    reward_count: 0
  ]

  @type t :: %__MODULE__{
          audience: :repo | [{String.t(), String.t()}] | nil,
          custom: map(),
          access_count: non_neg_integer(),
          last_accessed_at: DateTime.t() | nil,
          created_at: DateTime.t(),
          cumulative_reward: float(),
          reward_count: non_neg_integer()
        }

  @doc "Creates a new metadata struct with the given options."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      audience: Keyword.get(opts, :audience),
      custom: Keyword.get(opts, :custom, %{}),
      access_count: Keyword.get(opts, :access_count, 0),
      last_accessed_at: Keyword.get(opts, :last_accessed_at),
      created_at: Keyword.get(opts, :created_at, DateTime.utc_now()),
      cumulative_reward: Keyword.get(opts, :cumulative_reward, 0.0),
      reward_count: Keyword.get(opts, :reward_count, 0)
    }
  end

  @doc "Combines caller maps, keeping the surviving node's values for duplicate keys."
  @spec merge_custom(t(), t()) :: t()
  def merge_custom(%__MODULE__{} = survivor, %__MODULE__{} = removed) do
    custom = Map.merge(Map.get(removed, :custom, %{}), Map.get(survivor, :custom, %{}))
    Map.put(survivor, :custom, custom)
  end

  @doc "Increments access count and updates last accessed timestamp."
  @spec record_access(t()) :: t()
  def record_access(%__MODULE__{} = meta) do
    %{meta | access_count: meta.access_count + 1, last_accessed_at: DateTime.utc_now()}
  end

  @doc "Adds a reward observation to the metadata."
  @spec update_reward(t(), float()) :: t()
  def update_reward(%__MODULE__{} = meta, reward) do
    %{
      meta
      | cumulative_reward: meta.cumulative_reward + reward,
        reward_count: meta.reward_count + 1
    }
  end

  @doc "Returns the average reward, or 0.0 if no rewards recorded."
  @spec avg_reward(t()) :: float()
  def avg_reward(%__MODULE__{reward_count: 0}), do: 0.0
  def avg_reward(%__MODULE__{} = meta), do: meta.cumulative_reward / meta.reward_count
end
