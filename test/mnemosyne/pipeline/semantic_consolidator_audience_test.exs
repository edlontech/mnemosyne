defmodule Mnemosyne.Pipeline.SemanticConsolidatorAudienceTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Mnemosyne.Graph
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Tag
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.NodeMetadata
  alias Mnemosyne.Pipeline.SemanticConsolidator

  setup :set_mimic_from_context

  test "equivalent facts in different audiences never enter a merge prompt" do
    graph =
      Graph.new()
      |> Graph.put_node(%Semantic{
        id: "a",
        proposition: "Public fact",
        confidence: 0.9,
        embedding: [1.0, 0.0]
      })
      |> Graph.put_node(%Semantic{
        id: "b",
        proposition: "Secret fact",
        confidence: 0.9,
        embedding: [1.0, 0.0]
      })
      |> Graph.put_node(%Tag{id: "tag", label: "same concept"})
      |> Graph.link("a", "tag", :membership)
      |> Graph.link("b", "tag", :membership)

    backend = %InMemory{
      graph: graph,
      metadata: %{
        "a" => NodeMetadata.new(audience: :repo),
        "b" => NodeMetadata.new(audience: [{"org", "security"}])
      }
    }

    parent = self()

    stub(Mnemosyne.MockLLM, :chat_structured, fn _messages, _schema, _opts ->
      send(parent, :merge_prompt)
      {:error, :not_expected}
    end)

    {:ok, config} =
      Zoi.parse(Mnemosyne.Config.t(), %{
        llm: %{model: "test", opts: %{}},
        embedding: %{model: "test", opts: %{}}
      })

    assert {:ok, %{merged: 0}, _} =
             SemanticConsolidator.consolidate(
               backend: {InMemory, backend},
               config: config,
               llm: Mnemosyne.MockLLM,
               embedding: Mnemosyne.MockEmbedding
             )

    refute_received :merge_prompt
  end
end
