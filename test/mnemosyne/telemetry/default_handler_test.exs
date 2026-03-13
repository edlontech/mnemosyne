defmodule Mnemosyne.Telemetry.DefaultHandlerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Mnemosyne.Telemetry.DefaultHandler

  setup do
    DefaultHandler.attach()
    on_exit(fn -> DefaultHandler.detach() end)
    :ok
  end

  test "logs stop events at debug level" do
    log =
      capture_log([level: :debug], fn ->
        :telemetry.execute(
          [:mnemosyne, :llm, :chat, :stop],
          %{
            duration: System.convert_time_unit(150, :millisecond, :native),
            tokens_input: 100,
            tokens_output: 50
          },
          %{model: "test-model", step: :infer_subgoal}
        )
      end)

    assert log =~ "llm.chat completed in"
    assert log =~ "tokens_in=100"
    assert log =~ "tokens_out=50"
    assert log =~ "model=test-model"
  end

  test "logs exception events at error level" do
    log =
      capture_log([level: :error], fn ->
        :telemetry.execute(
          [:mnemosyne, :llm, :chat, :exception],
          %{duration: System.convert_time_unit(50, :millisecond, :native)},
          %{kind: :error, reason: :timeout, stacktrace: []}
        )
      end)

    assert log =~ "llm.chat failed after"
    assert log =~ "timeout"
  end

  test "detach/0 stops logging" do
    DefaultHandler.detach()

    log =
      capture_log([level: :debug], fn ->
        :telemetry.execute(
          [:mnemosyne, :llm, :chat, :stop],
          %{duration: 1000},
          %{}
        )
      end)

    assert log == ""
  end

  test "formats extra measurements in stop events" do
    log =
      capture_log([level: :debug], fn ->
        :telemetry.execute(
          [:mnemosyne, :graph, :apply_changeset, :stop],
          %{
            duration: System.convert_time_unit(10, :millisecond, :native),
            nodes_added: 5,
            links_added: 3
          },
          %{}
        )
      end)

    assert log =~ "graph.apply_changeset completed in"
    assert log =~ "nodes=5"
    assert log =~ "links=3"
  end

  test "stop events with no extra measurements show only duration" do
    log =
      capture_log([level: :debug], fn ->
        :telemetry.execute(
          [:mnemosyne, :storage, :persist, :stop],
          %{duration: System.convert_time_unit(20, :millisecond, :native)},
          %{}
        )
      end)

    assert log =~ "storage.persist completed in"
    assert log =~ "ms"
  end
end
