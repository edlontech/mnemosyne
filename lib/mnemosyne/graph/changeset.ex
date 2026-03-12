defmodule Mnemosyne.Graph.Changeset do
  @moduledoc """
  Batched mutations for the knowledge graph.

  A changeset accumulates node additions and link operations that can
  be applied atomically to a `Mnemosyne.Graph`.
  """
  use TypedStruct

  typedstruct do
    field :additions, [struct()], default: []
    field :links, [{String.t(), String.t()}], default: []
  end

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec add_node(t(), struct()) :: t()
  def add_node(%__MODULE__{} = cs, node) do
    %{cs | additions: [node | cs.additions]}
  end

  @spec add_link(t(), String.t(), String.t()) :: t()
  def add_link(%__MODULE__{} = cs, id_a, id_b) do
    %{cs | links: [{id_a, id_b} | cs.links]}
  end

  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = a, %__MODULE__{} = b) do
    %__MODULE__{
      additions: a.additions ++ b.additions,
      links: a.links ++ b.links
    }
  end
end
