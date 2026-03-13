defmodule Mnemosyne.Errors.Invalid.ConfigError do
  @moduledoc """
  Raised when Mnemosyne configuration is missing or invalid.
  """
  use Splode.Error, fields: [:reason], class: :invalid

  @type t :: %__MODULE__{}

  def message(%{reason: reason}) do
    "invalid configuration: #{format_reason(reason)}"
  end

  defp format_reason(:no_config), do: "no :mnemosyne config found in application environment"
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
