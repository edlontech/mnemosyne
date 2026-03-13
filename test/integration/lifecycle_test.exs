defmodule Mnemosyne.Integration.LifecycleTest do
  use Mnemosyne.IntegrationCase, async: false

  @moduletag :tmp_dir

  alias Mnemosyne.Pipeline.Reasoning.ReasonedMemory

  @tag timeout: 120_000
  test "full memory write-read cycle with real LLM and embeddings" do
    {:ok, session_id} = Mnemosyne.start_session("Learning Elixir OTP patterns")

    :ok =
      Mnemosyne.append(
        session_id,
        "GenServer is a behaviour module for implementing server processes in Elixir. It provides init/1, handle_call/3, handle_cast/2, and handle_info/2 callbacks.",
        "Studied the GenServer documentation and wrote a simple counter GenServer with increment and get operations."
      )

    :ok =
      Mnemosyne.append(
        session_id,
        "Supervisors monitor child processes and restart them according to a strategy. The common strategies are :one_for_one, :one_for_all, and :rest_for_one.",
        "Built a supervision tree with a top-level supervisor using :one_for_one strategy to manage multiple GenServer workers."
      )

    :ok =
      Mnemosyne.append(
        session_id,
        "Task module provides conveniences for spawning and awaiting async computations. Task.async/1 and Task.await/2 are used for fire-and-forget and result-gathering patterns.",
        "Implemented parallel data fetching using Task.async_stream to process multiple API calls concurrently."
      )

    assert :ok =
             Mnemosyne.close_and_commit(session_id,
               max_polls: 600,
               poll_interval: 200,
               max_retries: 2
             )

    graph = Mnemosyne.get_graph()
    assert map_size(graph.nodes) > 0

    node_types =
      graph.nodes
      |> Map.values()
      |> Enum.map(& &1.__struct__)
      |> Enum.uniq()

    assert node_types != []
    assert Mnemosyne.Graph.Node.Episodic in node_types

    known_types = [
      Mnemosyne.Graph.Node.Episodic,
      Mnemosyne.Graph.Node.Semantic,
      Mnemosyne.Graph.Node.Procedural,
      Mnemosyne.Graph.Node.Subgoal,
      Mnemosyne.Graph.Node.Source,
      Mnemosyne.Graph.Node.Tag,
      Mnemosyne.Graph.Node.Intent
    ]

    for type <- node_types do
      assert type in known_types, "Unexpected node type: #{inspect(type)}"
    end

    assert {:ok, %ReasonedMemory{} = result} =
             Mnemosyne.recall("how do supervisors work in Elixir?")

    assert result.episodic != nil or result.semantic != nil or result.procedural != nil
  end

  @tag timeout: 120_000
  test "recall_in_context augments query with session context" do
    {:ok, write_session} = Mnemosyne.start_session("Understanding process isolation in BEAM")

    :ok =
      Mnemosyne.append(
        write_session,
        "Each Erlang process has its own heap and stack, providing strong isolation. A crash in one process does not affect others.",
        "Experimented with spawning processes that crash and observed that the parent process continues running unaffected."
      )

    assert :ok =
             Mnemosyne.close_and_commit(write_session,
               max_polls: 600,
               poll_interval: 200,
               max_retries: 2
             )

    graph = Mnemosyne.get_graph()
    assert map_size(graph.nodes) > 0

    {:ok, read_session} = Mnemosyne.start_session("Exploring BEAM internals")

    :ok =
      Mnemosyne.append(
        read_session,
        "The BEAM scheduler distributes work across available CPU cores using preemptive scheduling with reduction counting.",
        "Read about how the BEAM VM manages scheduling and ran observer to see scheduler utilization across cores."
      )

    assert {:ok, %ReasonedMemory{} = result} =
             Mnemosyne.recall_in_context(read_session, "how does process memory work?")

    assert result.episodic != nil or result.semantic != nil or result.procedural != nil
  end
end
