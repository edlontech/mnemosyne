defmodule Mnemosyne.ValueFunctions.ProceduralEqual do
  @moduledoc """
  Value function for procedural instruction matching.

  Uses a high threshold (0.8) to ensure strong similarity
  for procedural memory nodes.
  """

  @behaviour Mnemosyne.ValueFunction

  @impl true
  def score(relevance, _node), do: relevance

  @impl true
  def threshold, do: 0.8

  @impl true
  def top_k, do: 10
end
