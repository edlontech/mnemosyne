defmodule Mnemosyne.Graph.Edge do
  @moduledoc """
  Defines the typed edge categories used in the knowledge graph.
  """

  @type edge_type :: :membership | :hierarchical | :provenance | :sibling

  @edge_types [:membership, :hierarchical, :provenance, :sibling]

  @doc "Returns all valid edge type atoms."
  @spec types() :: [edge_type()]
  def types, do: @edge_types

  @doc "Returns a map with all edge types initialized to empty MapSets."
  @spec empty_links() :: %{edge_type() => MapSet.t()}
  def empty_links do
    Map.new(@edge_types, fn t -> {t, MapSet.new()} end)
  end
end
