defmodule Mnemosyne.Notifier do
  @moduledoc """
  Behaviour for pluggable event notification.

  Implementations receive real-time events about graph changes,
  session transitions, and maintenance operations.
  """

  require Logger

  @type event ::
          {:changeset_applied, Mnemosyne.Graph.Changeset.t()}
          | {:nodes_deleted, [String.t()]}
          | {:decay_completed,
             %{
               checked: non_neg_integer(),
               deleted: non_neg_integer(),
               deleted_ids: [String.t()]
             }}
          | {:consolidation_completed,
             %{
               checked: non_neg_integer(),
               deleted: non_neg_integer(),
               deleted_ids: [String.t()]
             }}
          | {:session_transition, session_id :: String.t(), old_state :: atom(),
             new_state :: atom()}
          | {:recall_executed, query :: String.t(), results :: term()}

  @callback notify(repo_id :: String.t(), event()) :: :ok

  @doc """
  Invokes `notifier.notify/2`, rescuing any exception and logging a warning.

  Always returns `:ok`.
  """
  @spec safe_notify(module(), String.t(), event()) :: :ok
  def safe_notify(notifier, repo_id, event) do
    notifier.notify(repo_id, event)
  rescue
    e ->
      Logger.warning("Notifier #{inspect(notifier)} failed: #{Exception.message(e)}")
      :ok
  end
end
