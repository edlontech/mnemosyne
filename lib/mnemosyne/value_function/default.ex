defmodule Mnemosyne.ValueFunction.Default do
  @moduledoc """
  Default value function combining relevance with recency,
  frequency, and reward signals from node metadata.

  Score formula: `relevance * recency_factor * frequency_factor * reward_factor`

  The `node` parameter is part of the `ValueFunction` behaviour contract,
  enabling custom implementations to score based on node type or content.
  This default implementation scores purely from metadata signals.

  When metadata is nil, returns raw relevance for backward compatibility.
  """

  @behaviour Mnemosyne.ValueFunction

  alias Mnemosyne.NodeMetadata

  @impl true
  def score(relevance, _node, nil, _params), do: relevance

  @impl true
  def score(relevance, _node, %NodeMetadata{} = meta, params) do
    relevance
    |> Kernel.*(recency_factor(meta, params))
    |> Kernel.*(frequency_factor(meta, params))
    |> Kernel.*(reward_factor(meta, params))
  end

  defp recency_factor(%NodeMetadata{} = meta, params) do
    lambda = Map.get(params, :lambda, 0.01)
    reference_time = meta.last_accessed_at || meta.created_at
    hours_since = DateTime.diff(DateTime.utc_now(), reference_time, :second) / 3600.0
    :math.exp(-lambda * hours_since)
  end

  defp frequency_factor(%NodeMetadata{access_count: count}, params) do
    k = Map.get(params, :k, 5)
    base_floor = Map.get(params, :base_floor, 0.3)
    max(base_floor, count / (count + k))
  end

  defp reward_factor(%NodeMetadata{reward_count: 0}, _params), do: 1.0

  defp reward_factor(%NodeMetadata{} = meta, params) do
    beta = Map.get(params, :beta, 1.0)
    avg = NodeMetadata.avg_reward(meta)
    1.0 / (1.0 + :math.exp(-beta * avg))
  end
end
