defmodule Mnemosyne.ValueFunctions.IntentRelevance do
  @moduledoc """
  Value function for intent node matching during retrieval.

  Uses cosine relevance with a moderate threshold since intents
  are abstract routing nodes that should match broadly.
  """

  @behaviour Mnemosyne.ValueFunction

  @impl true
  def score(relevance, _node), do: relevance

  @impl true
  def threshold, do: 0.7

  @impl true
  def top_k, do: 10
end
