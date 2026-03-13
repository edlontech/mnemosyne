defmodule Mnemosyne.Errors.Framework.SessionError do
  @moduledoc """
  Raised when a session operation is invalid for the current state.
  """
  use Splode.Error, fields: [:reason, :state], class: :framework

  @type t :: %__MODULE__{}

  def message(%{reason: reason, state: state}) when not is_nil(state) do
    "session error (state=#{state}): #{format_reason(reason)}"
  end

  def message(%{reason: reason}) do
    "session error: #{format_reason(reason)}"
  end

  defp format_reason(:not_ready), do: "no changeset ready to commit"
  defp format_reason(:not_collecting), do: "session is not collecting observations"
  defp format_reason(:not_idle), do: "session must be idle for this operation"
  defp format_reason(:not_discardable), do: "nothing to discard in current state"
  defp format_reason(:invalid_operation), do: "operation not valid in current state"
  defp format_reason(:extraction_in_progress), do: "extraction is still running"
  defp format_reason(:session_failed), do: "session is in failed state"
  defp format_reason(reason), do: inspect(reason)
end
