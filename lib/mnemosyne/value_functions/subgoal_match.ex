defmodule Mnemosyne.ValueFunctions.SubgoalMatch do
  @moduledoc """
  Value function for subgoal segmentation matching.

  Threshold (0.75) aligns with the segmentation boundary
  defined in the PlugMem paper.
  """

  @behaviour Mnemosyne.ValueFunction

  @impl true
  def score(relevance, _node), do: relevance

  @impl true
  def threshold, do: 0.75

  @impl true
  def top_k, do: 10
end
