defmodule Mnemosyne.Notifier do
  @moduledoc """
  Behaviour for pluggable event notification.

  Implementations receive real-time events about graph changes,
  session transitions, and maintenance operations.
  """

  require Logger

  @type metadata :: %{
          optional(:session_id) => String.t() | nil,
          optional(:trace) => struct() | nil,
          optional(:node_ids) => [String.t()]
        }

  @type event ::
          {:changeset_applied, Mnemosyne.Graph.Changeset.t(), metadata()}
          | {:nodes_deleted, [String.t()], metadata()}
          | {:decay_completed,
             %{
               checked: non_neg_integer(),
               deleted: non_neg_integer(),
               deleted_ids: [String.t()]
             }, metadata()}
          | {:consolidation_completed,
             %{
               checked: non_neg_integer(),
               deleted: non_neg_integer(),
               deleted_ids: [String.t()]
             }, metadata()}
          | {:validation_completed,
             %{
               checked: non_neg_integer(),
               penalized: non_neg_integer(),
               orphaned: non_neg_integer()
             }, metadata()}
          | {:session_transition, session_id :: String.t(), old_state :: atom(),
             new_state :: atom(), metadata()}
          | {:recall_executed, query :: String.t(), results :: term(), metadata()}
          | {:recall_failed, query :: String.t(), reason :: term(), metadata()}
          | {:step_appended, session_id :: String.t(),
             %{
               step_index: non_neg_integer(),
               trajectory_id: String.t(),
               boundary_detected: boolean()
             }, metadata()}
          | {:trajectory_committed, session_id :: String.t(), trajectory_id :: String.t(),
             %{node_count: non_neg_integer(), node_ids: [String.t()]}, metadata()}
          | {:trajectory_flushed, session_id :: String.t(), trajectory_id :: String.t(),
             %{node_count: non_neg_integer(), node_ids: [String.t()]}, metadata()}
          | {:session_expired, session_id :: String.t(), metadata()}
          | {:trajectory_extraction_failed, session_id :: String.t(), trajectory_id :: String.t(),
             reason :: term(), metadata()}

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
