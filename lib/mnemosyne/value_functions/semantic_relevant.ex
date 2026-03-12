defmodule Mnemosyne.ValueFunctions.SemanticRelevant do
  @moduledoc """
  Value function for semantic memory nodes.

  Accepts any positive relevance (threshold 0.0) and returns
  up to 20 results.
  """

  @behaviour Mnemosyne.ValueFunction

  @impl true
  def score(relevance, _node), do: relevance

  @impl true
  def threshold, do: 0.0

  @impl true
  def top_k, do: 20
end
