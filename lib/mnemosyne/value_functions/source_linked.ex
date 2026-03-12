defmodule Mnemosyne.ValueFunctions.SourceLinked do
  @moduledoc """
  Value function for provenance link tracking.

  Accepts any positive relevance (threshold 0.0) with a large
  top_k (50) to capture the full provenance chain.
  """

  @behaviour Mnemosyne.ValueFunction

  @impl true
  def score(relevance, _node), do: relevance

  @impl true
  def threshold, do: 0.0

  @impl true
  def top_k, do: 50
end
