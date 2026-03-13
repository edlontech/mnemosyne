defmodule Mnemosyne.Errors.Framework.AdapterError do
  @moduledoc """
  Raised when an LLM or embedding adapter encounters an error.
  """
  use Splode.Error, fields: [:adapter, :operation, :reason], class: :framework

  @type t :: %__MODULE__{}

  def message(%{adapter: adapter, operation: operation, reason: reason}) do
    parts = [adapter, operation] |> Enum.reject(&is_nil/1) |> Enum.join(".")
    "adapter error#{if parts != "", do: " in #{parts}", else: ""}: #{inspect(reason)}"
  end
end
