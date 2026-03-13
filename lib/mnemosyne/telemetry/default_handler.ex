defmodule Mnemosyne.Telemetry.DefaultHandler do
  @moduledoc """
  Optional telemetry handler that logs Mnemosyne events via Logger.

  Attach in your application supervision tree:

      Mnemosyne.Telemetry.DefaultHandler.attach()

  All log entries use `domain: [:mnemosyne]` metadata for filtering.
  """
  require Logger

  @handler_prefix "mnemosyne-default-handler"

  @doc "Attaches Logger handlers to all Mnemosyne telemetry events."
  @spec attach() :: :ok
  def attach do
    events = Mnemosyne.Telemetry.events()

    for prefix <- events do
      :telemetry.attach(
        "#{@handler_prefix}.#{Enum.join(prefix, ".")}",
        prefix ++ [:stop],
        &__MODULE__.handle_stop/4,
        nil
      )

      :telemetry.attach(
        "#{@handler_prefix}.#{Enum.join(prefix, ".")}.exception",
        prefix ++ [:exception],
        &__MODULE__.handle_exception/4,
        nil
      )
    end

    :ok
  end

  @doc "Detaches all handlers."
  @spec detach() :: :ok
  def detach do
    for prefix <- Mnemosyne.Telemetry.events() do
      name = Enum.join(prefix, ".")
      :telemetry.detach("#{@handler_prefix}.#{name}")
      :telemetry.detach("#{@handler_prefix}.#{name}.exception")
    end

    :ok
  end

  @doc false
  def handle_stop(event, measurements, metadata, _config) do
    event_name = event |> Enum.drop(1) |> Enum.drop(-1) |> Enum.join(".")
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    extra = format_extra(measurements, metadata)

    Logger.debug("#{event_name} completed in #{duration_ms}ms#{extra}")
  end

  @doc false
  def handle_exception(event, measurements, metadata, _config) do
    event_name = event |> Enum.drop(1) |> Enum.drop(-1) |> Enum.join(".")
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.error("#{event_name} failed after #{duration_ms}ms: #{inspect(metadata[:reason])}")
  end

  defp format_extra(measurements, metadata) do
    parts =
      []
      |> maybe_add("tokens_in", measurements[:tokens_input])
      |> maybe_add("tokens_out", measurements[:tokens_output])
      |> maybe_add("batch_size", measurements[:batch_size])
      |> maybe_add("nodes", measurements[:nodes_added])
      |> maybe_add("links", measurements[:links_added])
      |> maybe_add("trajectories", measurements[:trajectory_count])
      |> maybe_add("candidates", measurements[:candidates_found])
      |> maybe_add("steps", measurements[:step_count])
      |> maybe_add("model", metadata[:model])
      |> maybe_add("step", metadata[:step])
      |> maybe_add("mode", metadata[:mode])
      |> maybe_add("from", metadata[:from_state])
      |> maybe_add("to", metadata[:to_state])
      |> Enum.reverse()

    case parts do
      [] -> ""
      _ -> " " <> Enum.join(parts, " ")
    end
  end

  defp maybe_add(parts, _label, nil), do: parts
  defp maybe_add(parts, label, value), do: ["#{label}=#{value}" | parts]
end
