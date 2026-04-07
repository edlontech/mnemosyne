defmodule Mnemosyne.Graph.Edge do
  @moduledoc """
  Defines the typed edge categories used in the knowledge graph.
  """

  @type edge_type :: :membership | :hierarchical | :provenance | :sibling

  @edge_types [:membership, :hierarchical, :provenance, :sibling]

  @spec types() :: [edge_type()]
  def types, do: @edge_types

  @spec empty_links() :: %{edge_type() => MapSet.t()}
  def empty_links do
    Map.new(@edge_types, fn t -> {t, MapSet.new()} end)
  end
end
