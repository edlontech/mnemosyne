defmodule Mnemosyne.Errors.Invalid.IngestionError do
  @moduledoc """
  Raised when a trajectory is invalid or conflicts with a prior ingestion.
  """

  use Splode.Error, fields: [:source_id, :reason], class: :invalid

  @type t :: %__MODULE__{}

  def message(%{source_id: source_id, reason: reason}) when not is_nil(source_id) do
    "ingestion error (source_id=#{inspect(source_id)}): #{format_reason(reason)}"
  end

  def message(%{reason: reason}) do
    "ingestion error: #{format_reason(reason)}"
  end

  defp format_reason(:invalid_trajectory), do: "trajectory must be a Mnemosyne.Trajectory"
  defp format_reason(:invalid_source_id), do: "source ID must be a non-blank binary"
  defp format_reason(:invalid_goal), do: "goal must be a non-blank binary"
  defp format_reason(:invalid_steps), do: "steps must be a non-empty list"
  defp format_reason(:invalid_step), do: "steps must contain binary observation and action values"
  defp format_reason(:invalid_metadata), do: "metadata must contain deterministic plain terms"
  defp format_reason(:source_conflict), do: "source ID conflicts with an existing ingestion"
  defp format_reason(reason), do: inspect(reason)
end
