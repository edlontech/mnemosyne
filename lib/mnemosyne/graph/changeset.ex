defmodule Mnemosyne.Graph.Changeset do
  @moduledoc """
  Batched mutations for the knowledge graph.

  A changeset accumulates node additions and link operations that can
  be applied atomically to a `Mnemosyne.Graph`.
  """
  use TypedStruct

  alias Mnemosyne.Graph.Edge
  alias Mnemosyne.NodeMetadata

  typedstruct do
    field :additions, [struct()], default: []
    field :links, [{String.t(), String.t(), Edge.edge_type()}], default: []
    field :metadata, %{String.t() => NodeMetadata.t()}, default: %{}
  end

  @doc "Creates an empty changeset."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Appends a node to the changeset's addition list."
  @spec add_node(t(), struct()) :: t()
  def add_node(%__MODULE__{} = cs, node) do
    %{cs | additions: [node | cs.additions]}
  end

  @doc "Records a typed link between two node IDs in the changeset."
  @spec add_link(t(), String.t(), String.t(), Edge.edge_type()) :: t()
  def add_link(%__MODULE__{} = cs, id_a, id_b, type)
      when type in [:membership, :hierarchical, :provenance, :sibling] do
    %{cs | links: [{id_a, id_b, type} | cs.links]}
  end

  @doc "Associates metadata with a node ID in the changeset."
  @spec put_metadata(t(), String.t(), NodeMetadata.t()) :: t()
  def put_metadata(%__MODULE__{} = cs, node_id, %NodeMetadata{} = meta) do
    %{cs | metadata: Map.put(cs.metadata, node_id, meta)}
  end

  @doc "Merges two changesets by concatenating their additions, links, and metadata maps."
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = a, %__MODULE__{} = b) do
    %__MODULE__{
      additions: a.additions ++ b.additions,
      links: a.links ++ b.links,
      metadata: Map.merge(a.metadata, b.metadata)
    }
  end
end
