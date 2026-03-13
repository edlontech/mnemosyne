defmodule Mnemosyne.Errors.Framework.StorageError do
  @moduledoc """
  Raised when a storage backend operation fails.
  """
  use Splode.Error, fields: [:operation, :reason], class: :framework

  @type t :: %__MODULE__{}

  def message(%{operation: operation, reason: reason}) when not is_nil(operation) do
    "storage error during #{operation}: #{inspect(reason)}"
  end

  def message(%{reason: reason}) do
    "storage error: #{inspect(reason)}"
  end
end
