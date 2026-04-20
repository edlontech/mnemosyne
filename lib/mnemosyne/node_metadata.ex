defmodule Mnemosyne.NodeMetadata do
  @moduledoc """
  Metadata tracked per node for value function scoring.

  Captures access patterns, temporal information, and accumulated
  rewards to enable recency, frequency, and reward-based scoring.
  """

  @enforce_keys [:created_at]
  defstruct [
    :created_at,
    access_count: 0,
    last_accessed_at: nil,
    cumulative_reward: 0.0,
    reward_count: 0
  ]

  @type t :: %__MODULE__{
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
      access_count: Keyword.get(opts, :access_count, 0),
      last_accessed_at: Keyword.get(opts, :last_accessed_at),
      created_at: Keyword.get(opts, :created_at, DateTime.utc_now()),
      cumulative_reward: Keyword.get(opts, :cumulative_reward, 0.0),
      reward_count: Keyword.get(opts, :reward_count, 0)
    }
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
