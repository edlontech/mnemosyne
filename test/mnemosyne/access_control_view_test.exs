defmodule Mnemosyne.AccessControl.ViewTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.AccessControl.View
  alias Mnemosyne.Graph
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.NodeMetadata

  test "usage and reward updates preserve the node audience" do
    metadata =
      NodeMetadata.new(audience: [{"org", "security"}])
      |> NodeMetadata.record_access()
      |> NodeMetadata.update_reward(0.8)

    assert Map.get(metadata, :audience) == [{"org", "security"}]
  end

  test "an audience-scoped view removes other nodes, metadata, and link references" do
    audience = [{"org", "security"}]

    visible = %Semantic{
      id: "visible",
      proposition: "Visible fact",
      confidence: 0.9,
      links: %{sibling: MapSet.new(["hidden", "legacy"])}
    }

    graph =
      Graph.new()
      |> Graph.put_node(visible)
      |> Graph.put_node(%Semantic{id: "hidden", proposition: "Hidden fact", confidence: 0.9})
      |> Graph.put_node(%Semantic{
        id: "legacy",
        proposition: "Unclassified fact",
        confidence: 0.9
      })

    state = %InMemory{
      graph: graph,
      metadata: %{
        "visible" => Map.put(NodeMetadata.new(), :audience, audience),
        "hidden" => Map.put(NodeMetadata.new(), :audience, :repo),
        "legacy" => NodeMetadata.new()
      }
    }

    assert {:ok, {InMemory, scoped}} = View.scope({InMemory, state}, audience)

    assert [%Semantic{id: "visible", links: %{sibling: ids}}] =
             Graph.nodes_by_type(scoped.graph, :semantic)

    assert MapSet.size(ids) == 0
    assert Map.keys(scoped.metadata) == ["visible"]
    assert scoped.persistence == nil
    assert scoped.ingestions == %{}
  end
end
