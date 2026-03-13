defmodule Mnemosyne.Errors.Framework.PipelineError do
  @moduledoc """
  Raised when a pipeline operation fails during extraction or reasoning.
  """
  use Splode.Error, fields: [:reason], class: :framework

  @type t :: %__MODULE__{}

  def message(%{reason: reason}) do
    "pipeline error: #{format_reason(reason)}"
  end

  defp format_reason(:extraction_failed), do: "extraction failed after all retries"
  defp format_reason(:extraction_timeout), do: "extraction timed out waiting for completion"
  defp format_reason({:task_crashed, inner}), do: "background task crashed: #{inspect(inner)}"
  defp format_reason(reason), do: inspect(reason)
end
