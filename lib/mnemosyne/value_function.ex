defmodule Mnemosyne.ValueFunction do
  @moduledoc """
  Behaviour for scoring memory nodes during retrieval.

  Implementations combine raw cosine relevance with node metadata
  (recency, frequency, reward) to produce a final score.
  """

  @default_recency_lambda :math.log(2.0) / (90 * 24)

  @doc "Returns the hourly decay rate for the default 90-day recency half-life."
  @spec default_recency_lambda() :: float()
  def default_recency_lambda, do: @default_recency_lambda

  @callback score(
              relevance :: float(),
              node :: struct(),
              metadata :: map() | nil,
              params :: map()
            ) :: float()
end
