defmodule Mnemosyne.Pipeline.IngestionTest.UnsafeMetadata do
  defstruct [:value]
end

defmodule Mnemosyne.Pipeline.IngestionTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Errors.Invalid.IngestionError
  alias Mnemosyne.IngestionReceipt
  alias Mnemosyne.Pipeline.Ingestion
  alias Mnemosyne.Pipeline.IngestionTest.UnsafeMetadata
  alias Mnemosyne.Trajectory

  test "prepares a valid trajectory" do
    trajectory = %Trajectory{
      source_id: "task-42",
      goal: "Diagnose intermittent timeouts",
      steps: [%{observation: "Timeout from upstream", action: "Inspect request logs"}],
      metadata: %{attempt: 1}
    }

    assert {:ok, digest} = Ingestion.prepare(trajectory)
    assert byte_size(digest) == 32
  end

  test "uses the versioned deterministic ETF fingerprint contract" do
    goal = "Diagnose intermittent timeouts"

    ordered_step_tuples = [
      {"Timeout from upstream", "Inspect request logs"},
      {"Second observation", "Inspect error rates"}
    ]

    metadata = %{attempt: 1, source: "production"}

    expected_digest =
      {:mnemosyne_trajectory, 1, goal, ordered_step_tuples, metadata}
      |> :erlang.term_to_binary([:deterministic, minor_version: 2])
      |> then(&:crypto.hash(:sha256, &1))

    trajectory = %Trajectory{
      source_id: "task-42",
      goal: goal,
      steps:
        Enum.map(ordered_step_tuples, fn {observation, action} ->
          %{observation: observation, action: action}
        end),
      metadata: metadata
    }

    assert {:ok, ^expected_digest} = Ingestion.prepare(trajectory)
  end

  test "represents a stored ingestion with source, nodes, and time" do
    stored_at = DateTime.utc_now()

    receipt = %IngestionReceipt{
      source_id: "task-42",
      node_ids: ["node-1", "node-2"],
      stored_at: stored_at
    }

    assert receipt.source_id == "task-42"
    assert receipt.node_ids == ["node-1", "node-2"]
    assert receipt.stored_at == stored_at
  end

  test "requires every receipt field" do
    assert_raise ArgumentError, ~r/\[:node_ids, :stored_at\]/, fn ->
      Code.eval_string("%Mnemosyne.IngestionReceipt{source_id: \"task-42\"}")
    end
  end

  test "uses payload identity rather than source identity" do
    trajectory = trajectory()
    same_payload = trajectory(source_id: "task-43")

    assert Ingestion.prepare(trajectory) == Ingestion.prepare(same_payload)
  end

  test "rejects source IDs that are blank or not binaries" do
    for source_id <- ["", " ", nil] do
      assert {:error, %IngestionError{source_id: ^source_id, reason: :invalid_source_id}} =
               Ingestion.prepare(trajectory(source_id: source_id))
    end
  end

  test "rejects invalid goals, steps, and metadata" do
    for {overrides, reason} <- [
          {[goal: " "], :invalid_goal},
          {[goal: nil], :invalid_goal},
          {[steps: []], :invalid_steps},
          {[steps: [%{observation: :not_binary, action: "Inspect logs"}]], :invalid_step},
          {[steps: [%{observation: "Inspect logs", action: :not_binary}]], :invalid_step},
          {[steps: [%{observation: "Inspect logs"}]], :invalid_step},
          {[metadata: []], :invalid_metadata}
        ] do
      assert {:error, %IngestionError{reason: ^reason}} = Ingestion.prepare(trajectory(overrides))
    end
  end

  test "rejects improper step lists" do
    steps = [%{observation: "Timeout from upstream", action: "Inspect request logs"} | :tail]

    assert {:error, %IngestionError{reason: :invalid_steps}} =
             Ingestion.prepare(trajectory(steps: steps))
  end

  test "accepts recursively deterministic metadata" do
    metadata = %{
      nil: nil,
      boolean: true,
      number: 1.5,
      binary: "value",
      atom: :value,
      list: [1, {:nested, %{value: "value"}}],
      tuple: {:tuple, 2},
      struct: %URI{scheme: "https", host: "example.com"}
    }

    assert {:ok, digest} = Ingestion.prepare(trajectory(metadata: metadata))
    assert byte_size(digest) == 32
  end

  test "rejects runtime terms nested in metadata" do
    port = Port.open({:spawn, "cat"}, [])
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)

    for value <- [self(), port, make_ref(), fn -> :ok end, %UnsafeMetadata{value: self()}] do
      assert {:error, %IngestionError{reason: :invalid_metadata}} =
               Ingestion.prepare(trajectory(metadata: %{nested: %{value: value}}))
    end
  end

  test "is stable across metadata map insertion order" do
    metadata = %{first: 1, second: %{enabled: true}}
    reordered_metadata = %{} |> Map.put(:second, %{enabled: true}) |> Map.put(:first, 1)

    assert Ingestion.prepare(trajectory(metadata: metadata)) ==
             Ingestion.prepare(trajectory(metadata: reordered_metadata))
  end

  test "changes when goal, metadata, step content, or step order changes" do
    steps = [
      %{observation: "Timeout from upstream", action: "Inspect request logs"},
      %{observation: "Second observation", action: "Inspect error rates"}
    ]

    trajectory = trajectory(steps: steps)
    {:ok, digest} = Ingestion.prepare(trajectory)

    assert {:ok, changed_goal} = Ingestion.prepare(trajectory(goal: "Investigate latency"))
    assert {:ok, changed_metadata} = Ingestion.prepare(trajectory(metadata: %{attempt: 2}))

    assert {:ok, changed_step_content} =
             Ingestion.prepare(
               trajectory(
                 steps: [
                   %{observation: "Timeout from upstream", action: "Restart service"},
                   %{observation: "Second observation", action: "Inspect error rates"}
                 ]
               )
             )

    assert {:ok, changed_step_order} = Ingestion.prepare(trajectory(steps: Enum.reverse(steps)))

    refute digest == changed_goal
    refute digest == changed_metadata
    refute digest == changed_step_content
    refute digest == changed_step_order
  end

  defp trajectory(overrides \\ []) do
    struct!(
      Trajectory,
      Keyword.merge(
        [
          source_id: "task-42",
          goal: "Diagnose intermittent timeouts",
          steps: [%{observation: "Timeout from upstream", action: "Inspect request logs"}],
          metadata: %{attempt: 1}
        ],
        overrides
      )
    )
  end
end
