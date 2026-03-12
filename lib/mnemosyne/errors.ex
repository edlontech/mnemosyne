defmodule Mnemosyne.Errors do
  @moduledoc """
  Top-level Splode error aggregator for Mnemosyne.

  Provides error classes for invalid input, framework-level failures,
  and unknown/unrecognized errors.
  """
  use Splode,
    error_classes: [
      invalid: Mnemosyne.Errors.Invalid,
      framework: Mnemosyne.Errors.Framework,
      unknown: Mnemosyne.Errors.Unknown
    ],
    unknown_error: Mnemosyne.Errors.Unknown.Unknown
end

defmodule Mnemosyne.Errors.Invalid do
  @moduledoc """
  Error class for validation and invalid-input errors.
  """
  use Splode.ErrorClass, class: :invalid
end

defmodule Mnemosyne.Errors.Framework do
  @moduledoc """
  Error class for internal framework-level errors.
  """
  use Splode.ErrorClass, class: :framework
end

defmodule Mnemosyne.Errors.Unknown do
  @moduledoc """
  Error class for unknown or unrecognized errors.
  """
  use Splode.ErrorClass, class: :unknown
end

defmodule Mnemosyne.Errors.Unknown.Unknown do
  @moduledoc """
  Fallback concrete error used when an error cannot be mapped
  to a known Splode error type.
  """
  use Splode.Error, fields: [:error, :value], class: :unknown

  @spec message(map()) :: String.t()
  def message(%{error: error}) do
    if is_binary(error), do: error, else: inspect(error)
  end
end
