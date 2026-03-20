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

  test "events/0 returns all event prefixes" do
    events = Telemetry.events()
    assert length(events) == 21
    assert [:mnemosyne, :llm, :chat] in events
    assert [:mnemosyne, :llm, :chat_structured] in events
    assert [:mnemosyne, :embedding, :embed] in events
    assert [:mnemosyne, :embedding, :embed_batch] in events
    assert [:mnemosyne, :episode, :append] in events
    assert [:mnemosyne, :structuring, :extract] in events
    assert [:mnemosyne, :retrieval, :retrieve] in events
    assert [:mnemosyne, :reasoning, :reason] in events
    assert [:mnemosyne, :decay, :prune] in events
    assert [:mnemosyne, :consolidator, :consolidate] in events
    assert [:mnemosyne, :intent_merger, :merge] in events
    assert [:mnemosyne, :session, :transition] in events
    assert [:mnemosyne, :repo, :open] in events
    assert [:mnemosyne, :repo, :close] in events
    assert [:mnemosyne, :graph, :apply_changeset] in events
    assert [:mnemosyne, :storage, :persist] in events
    assert [:mnemosyne, :storage, :load] in events
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
