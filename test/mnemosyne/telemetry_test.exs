defmodule Mnemosyne.TelemetryTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Telemetry

  setup do
    test_pid = self()
    handler_id = "test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      for prefix <- Telemetry.events(), suffix <- [:start, :stop, :exception] do
        prefix ++ [suffix]
      end,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "events/0 returns the complete active event catalog" do
    events = Telemetry.events()

    expected_events =
      MapSet.new([
        [:mnemosyne, :llm, :chat],
        [:mnemosyne, :llm, :chat_structured],
        [:mnemosyne, :embedding, :embed],
        [:mnemosyne, :embedding, :embed_batch],
        [:mnemosyne, :episode, :append],
        [:mnemosyne, :structuring, :extract],
        [:mnemosyne, :structuring, :extract_trajectory],
        [:mnemosyne, :retrieval, :retrieve],
        [:mnemosyne, :retrieval, :hop_control],
        [:mnemosyne, :retrieval, :hop_refinement],
        [:mnemosyne, :reasoning, :reason],
        [:mnemosyne, :tag_deduplicator, :deduplicate],
        [:mnemosyne, :decay, :prune],
        [:mnemosyne, :consolidator, :consolidate],
        [:mnemosyne, :intent_merger, :merge],
        [:mnemosyne, :episodic_validation, :validate],
        [:mnemosyne, :graph_repair, :repair],
        [:mnemosyne, :ingestion, :ingest],
        [:mnemosyne, :repo, :open],
        [:mnemosyne, :repo, :close],
        [:mnemosyne, :memory_store, :queue],
        [:mnemosyne, :graph, :apply_changeset]
      ])

    assert MapSet.new(events) == expected_events
    assert [:mnemosyne, :ingestion, :ingest] in events
    assert [:mnemosyne, :memory_store, :queue] in events
    refute Enum.any?(events, &match?([:mnemosyne, :session | _], &1))
  end

  test "span/3 emits start and stop events on success" do
    result =
      Telemetry.span([:llm, :chat], %{model: "test"}, fn ->
        {:ok, %{tokens_input: 10, tokens_output: 5}}
      end)

    assert result == :ok

    assert_receive {:telemetry, [:mnemosyne, :llm, :chat, :start], %{system_time: _},
                    %{model: "test"}}

    assert_receive {:telemetry, [:mnemosyne, :llm, :chat, :stop], measurements, %{model: "test"}}
    assert is_integer(measurements.duration)
    assert measurements.tokens_input == 10
    assert measurements.tokens_output == 5
  end

  test "span/3 emits exception event on raise" do
    assert_raise RuntimeError, fn ->
      Telemetry.span([:llm, :chat], %{model: "test"}, fn ->
        raise "boom"
      end)
    end

    assert_receive {:telemetry, [:mnemosyne, :llm, :chat, :start], _, _}
    assert_receive {:telemetry, [:mnemosyne, :llm, :chat, :exception], %{duration: _}, metadata}
    assert metadata.kind == :error
  end
end
