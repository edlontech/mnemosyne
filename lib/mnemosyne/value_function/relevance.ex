defmodule Mnemosyne.ValueFunction.Relevance do
  @moduledoc """
  Value function that returns raw relevance, ignoring metadata.

  Retrieval passes it to `GraphBackend.find_candidates/6` so per-type
  thresholds and `top_k` apply to raw cosine similarity. The configured
  value function then ranks the final candidate pool once.
  """

  @behaviour Mnemosyne.ValueFunction

  @impl true
  def score(relevance, _node, _metadata, _params), do: relevance
end
