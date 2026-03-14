defmodule Mnemosyne.ValueFunction do
  @moduledoc """
  Behaviour for scoring memory nodes during retrieval.

  Implementations combine raw cosine relevance with node metadata
  (recency, frequency, reward) to produce a final score.
  """

  @callback score(
              relevance :: float(),
              node :: struct(),
              metadata :: map() | nil,
              params :: map()
            ) :: float()
end
