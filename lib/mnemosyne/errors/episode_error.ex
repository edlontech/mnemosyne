defmodule Mnemosyne.Errors.Invalid.EpisodeError do
  @moduledoc """
  Raised when an episode operation violates preconditions.
  """
  use Splode.Error, fields: [:reason], class: :invalid

  @type t :: %__MODULE__{}

  def message(%{reason: reason}) do
    "episode error: #{format_reason(reason)}"
  end

  defp format_reason(:episode_closed), do: "cannot append to a closed episode"
  defp format_reason(:already_closed), do: "episode is already closed"
  defp format_reason(:episode_not_closed), do: "episode must be closed before extraction"
  defp format_reason(reason), do: inspect(reason)
end
