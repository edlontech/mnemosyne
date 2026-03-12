defmodule Mnemosyne.ValueFunctions.TagExact do
  @moduledoc """
  Value function for near-exact tag label matching.

  Uses a high threshold (0.9) to ensure only very close
  tag matches are returned.
  """

  @behaviour Mnemosyne.ValueFunction

  @impl true
  def score(relevance, _node), do: relevance

  @impl true
  def threshold, do: 0.9

  @impl true
  def top_k, do: 10
end
