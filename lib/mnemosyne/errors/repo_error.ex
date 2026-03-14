defmodule Mnemosyne.Errors.Framework.RepoError do
  @moduledoc """
  Raised when a repository lifecycle operation fails.
  """
  use Splode.Error, fields: [:repo_id, :reason], class: :framework

  @type t :: %__MODULE__{}

  def message(%{repo_id: repo_id, reason: reason}) when not is_nil(repo_id) do
    "repo #{inspect(repo_id)}: #{format_reason(reason)}"
  end

  def message(%{reason: reason}), do: format_reason(reason)

  defp format_reason(:already_open), do: "repository is already open"
  defp format_reason(reason), do: inspect(reason)
end
