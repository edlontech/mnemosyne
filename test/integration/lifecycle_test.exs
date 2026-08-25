defmodule Mnemosyne.Integration.LifecycleTest do
  use Mnemosyne.IntegrationCase, async: false

  @moduletag :tmp_dir

  alias Mnemosyne.Graph.Node, as: NodeProtocol
  alias Mnemosyne.Graph.Node.Episodic
  alias Mnemosyne.Graph.Node.Procedural
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Source
  alias Mnemosyne.IngestionReceipt
  alias Mnemosyne.Pipeline.Reasoning.ReasonedMemory
  alias Mnemosyne.Pipeline.RecallResult
  alias Mnemosyne.Trajectory

  @repo "integration"

  @tag timeout: 120_000
  test "ingests and recalls a complete trajectory with real LLM and embeddings" do
    source_id = "integration-elixir-otp-trajectory"

    trajectory = %Trajectory{
      source_id: source_id,
      goal: "Learning Elixir OTP patterns",
      steps: [
        %{
          observation:
            "GenServer is a behaviour module for implementing server processes in Elixir. It provides init/1, handle_call/3, handle_cast/2, and handle_info/2 handlers.",
          action:
            "Studied the GenServer documentation and wrote a simple counter GenServer with increment and get operations."
        },
        %{
          observation:
            "Supervisors monitor child processes and restart them according to a strategy. The common strategies are :one_for_one, :one_for_all, and :rest_for_one.",
          action:
            "Built a supervision tree with a top-level supervisor using :one_for_one strategy to manage multiple GenServer workers."
        },
        %{
          observation:
            "Task module provides conveniences for spawning and awaiting async computations. Task.async/1 and Task.await/2 are used for fire-and-forget and result-gathering patterns.",
          action:
            "Implemented parallel data fetching using Task.async_stream to process multiple API calls concurrently."
        }
      ],
      metadata: %{topic: "elixir-otp"}
    }

    assert {:ok,
            %IngestionReceipt{
              source_id: ^source_id,
              node_ids: node_ids,
              stored_at: %DateTime{}
            } = receipt} = Mnemosyne.ingest(@repo, trajectory)

    assert node_ids != []

    graph = Mnemosyne.get_graph(@repo)
    assert Enum.all?(node_ids, &Map.has_key?(graph.nodes, &1))

    node_types =
      graph.nodes
      |> Map.values()
      |> Enum.map(& &1.__struct__)
      |> Enum.uniq()

    assert Episodic in node_types

    known_types = [
      Episodic,
      Semantic,
      Procedural,
      Mnemosyne.Graph.Node.Subgoal,
      Source,
      Mnemosyne.Graph.Node.Tag,
      Mnemosyne.Graph.Node.Intent
    ]

    for type <- node_types do
      assert type in known_types, "Unexpected node type: #{inspect(type)}"
    end

    source_nodes = Enum.filter(graph.nodes, fn {_id, node} -> match?(%Source{}, node) end)
    semantic_nodes = Enum.filter(graph.nodes, fn {_id, node} -> match?(%Semantic{}, node) end)
    procedural_nodes = Enum.filter(graph.nodes, fn {_id, node} -> match?(%Procedural{}, node) end)

    episodic_ids =
      graph.nodes
      |> Map.values()
      |> Enum.filter(&match?(%Episodic{}, &1))
      |> MapSet.new(& &1.id)

    assert source_nodes != [], "expected source nodes in graph"
    assert Enum.all?(source_nodes, fn {_id, source} -> source.episode_id == source_id end)
    assert semantic_nodes != [], "expected semantic nodes in graph"
    assert procedural_nodes != [], "expected procedural nodes in graph"
    assert MapSet.size(episodic_ids) > 0, "expected episodic nodes in graph"

    Enum.each(semantic_nodes, fn {_id, semantic} ->
      provenance =
        semantic
        |> NodeProtocol.links(:provenance)
        |> MapSet.intersection(episodic_ids)

      assert MapSet.size(provenance) > 0,
             "semantic node #{semantic.id} should have provenance links to episodic nodes"
    end)

    Enum.each(procedural_nodes, fn {_id, procedural} ->
      provenance =
        procedural
        |> NodeProtocol.links(:provenance)
        |> MapSet.intersection(episodic_ids)

      assert MapSet.size(provenance) > 0,
             "procedural node #{procedural.id} should have provenance links to episodic nodes"
    end)

    assert {:ok, ^receipt} = Mnemosyne.ingest(@repo, trajectory)
    assert graph == Mnemosyne.get_graph(@repo)

    assert {:ok, %RecallResult{reasoned: %ReasonedMemory{} = result}} =
             Mnemosyne.recall(@repo, "how do supervisors work in Elixir?")

    assert result.episodic != nil or result.semantic != nil or result.procedural != nil
  end
end
