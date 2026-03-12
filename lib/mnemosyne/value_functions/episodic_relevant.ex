defmodule Mnemosyne.ValueFunctions.EpisodicRelevant do
  @moduledoc """
  Value function for episodic memory nodes.

  Accepts any positive relevance (threshold 0.0) and returns
  up to 30 results to capture broader episodic context.
  """

  @behaviour Mnemosyne.ValueFunction

  @impl true
  def score(relevance, _node), do: relevance

  @impl true
  def threshold, do: 0.0

  @impl true
  def top_k, do: 30
end
