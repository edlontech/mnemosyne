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
        [:mnemosyne, :model, :call],
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

  test "span/3 merges terminal metadata only into the stop event" do
    assert :ok ==
             Telemetry.span([:model, :call], %{repo_id: "repo-1"}, fn ->
               {:ok, %{input_tokens: 3}, %{status: :ok, response_model: "model-1"}}
             end)

    assert_receive {:telemetry, [:mnemosyne, :model, :call, :start], _, start_metadata}
    assert start_metadata == %{repo_id: "repo-1"}

    assert_receive {:telemetry, [:mnemosyne, :model, :call, :stop], measurements, metadata}
    assert measurements.input_tokens == 3
    assert metadata == %{repo_id: "repo-1", status: :ok, response_model: "model-1"}
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
    assert metadata.exception_kind == :error
    assert metadata.status == :exception
  end

  test "span/3 preserves an existing kind on exception" do
    assert_raise RuntimeError, fn ->
      Telemetry.span([:model, :call], %{kind: :llm}, fn ->
        raise "boom"
      end)
    end

    assert_receive {:telemetry, [:mnemosyne, :model, :call, :exception], _, metadata}
    assert metadata.kind == :llm
    assert metadata.exception_kind == :error
  end

  test "span/3 emits exception events for throw and exit" do
    assert catch_throw(Telemetry.span([:llm, :chat], %{model: "test"}, fn -> throw(:boom) end)) ==
             :boom

    assert_receive {:telemetry, [:mnemosyne, :llm, :chat, :exception], _, throw_metadata}
    assert throw_metadata.kind == :throw
    assert throw_metadata.exception_kind == :throw
    assert throw_metadata.reason == :boom
    assert throw_metadata.status == :exception

    assert catch_exit(Telemetry.span([:llm, :chat], %{model: "test"}, fn -> exit(:boom) end)) ==
             :boom

    assert_receive {:telemetry, [:mnemosyne, :llm, :chat, :exception], _, exit_metadata}
    assert exit_metadata.kind == :exit
    assert exit_metadata.exception_kind == :exit
    assert exit_metadata.reason == :boom
    assert exit_metadata.status == :exception
  end
end
