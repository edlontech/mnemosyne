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

  test "logs model-call costs and terminal dimensions" do
    log =
      capture_log([level: :debug], fn ->
        :telemetry.execute(
          [:mnemosyne, :model, :call, :stop],
          %{
            duration: System.convert_time_unit(150, :millisecond, :native),
            input_tokens: 100,
            output_tokens: 50,
            total_cost: 0.0012
          },
          %{
            repo_id: "repo-1",
            step: :get_semantic,
            requested_model: "requested-model",
            response_model: "response-model",
            currency: "USD",
            status: :ok,
            labels: %{api_key: "never-log"}
          }
        )
      end)

    assert log =~ "model.call completed in"
    assert log =~ "repo=repo-1"
    assert log =~ "tokens_in=100"
    assert log =~ "tokens_out=50"
    assert log =~ "total_cost=0.0012"
    assert log =~ "currency=USD"
    assert log =~ "status=ok"
    assert log =~ "requested_model=requested-model"
    assert log =~ "response_model=response-model"
    assert log =~ "step=get_semantic"
    refute log =~ "api_key"
    refute log =~ "never-log"
  end

  test "logs error model calls without unknown cost or currency" do
    log =
      capture_log([level: :debug], fn ->
        :telemetry.execute(
          [:mnemosyne, :model, :call, :stop],
          %{
            duration: System.convert_time_unit(50, :millisecond, :native),
            total_cost: nil
          },
          %{
            status: :error,
            currency: "",
            requested_model: "requested-model",
            response_model: "requested-model"
          }
        )
      end)

    assert log =~ "model.call completed in"
    assert log =~ "status=error"
    assert log =~ "requested_model=requested-model"
    assert log =~ "response_model=requested-model"
    refute log =~ "total_cost="
    refute log =~ "currency="
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
          [:mnemosyne, :repo, :close, :stop],
          %{duration: System.convert_time_unit(20, :millisecond, :native)},
          %{}
        )
      end)

    assert log =~ "repo.close completed in"
    assert log =~ "ms"
  end
end
