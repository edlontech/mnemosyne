defmodule Mnemosyne.Errors.Framework.NotFoundError do
  @moduledoc """
  Raised when a referenced resource cannot be found.
  """
  use Splode.Error, fields: [:resource, :id], class: :framework

  @type t :: %__MODULE__{}

  def message(%{resource: resource, id: id}) when not is_nil(resource) and not is_nil(id) do
    "#{resource} #{id} not found"
  end

  def message(%{resource: resource}) when not is_nil(resource) do
    "#{resource} not found"
  end

  def message(_) do
    "resource not found"
  end
end
