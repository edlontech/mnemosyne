defmodule Mnemosyne.Errors.Invalid.AccessError do
  @moduledoc """
  Returned when access-control configuration, input, or authorization fails.
  """

  use Splode.Error, fields: [:reason], class: :invalid

  @type t :: %__MODULE__{}

  @spec message(map()) :: String.t()
  def message(%{reason: reason}), do: "access control error: #{format_reason(reason)}"

  defp format_reason(:invalid_config), do: "configuration must select a valid Cedar policy"

  defp format_reason(:dependency_unavailable),
    do: "the optional ex_cedar dependency is unavailable"

  defp format_reason(:policy_compile_failed), do: "Cedar policy compilation failed"
  defp format_reason(:schema_compile_failed), do: "Cedar schema compilation failed"
  defp format_reason(:policy_validation_failed), do: "Cedar policy validation failed"

  defp format_reason(:invalid_audience),
    do: "audience must be :repo or organization-qualified groups"

  defp format_reason(:invalid_auth), do: "authorization context is invalid"
  defp format_reason(:invalid_repo_id), do: "repository ID must be a non-blank binary"
  defp format_reason(:invalid_action), do: "action must be :read or :ingest"
  defp format_reason(:invalid_resource), do: "resource is invalid"
  defp format_reason(:not_repo_member), do: "principal is not a repository member"
  defp format_reason(:authorization_failed), do: "Cedar authorization failed"
  defp format_reason(:evaluation_failed), do: "Cedar policy evaluation failed"
  defp format_reason(:forbidden), do: "access forbidden"
  defp format_reason(:access_control_required), do: "an audience requires repo access control"
  defp format_reason(:immutable_audience), do: "an assigned audience cannot change"
  defp format_reason(:raw_graph_disabled), do: "raw graph export is disabled for protected repos"

  defp format_reason(:raw_changeset_disabled),
    do: "raw changesets are disabled for protected repos"

  defp format_reason(:raw_deletion_disabled), do: "raw deletion is disabled for protected repos"
  defp format_reason(:maintenance_busy), do: "maintenance requires an idle write lane"
  defp format_reason(reason), do: inspect(reason)
end
