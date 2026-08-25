defmodule Mnemosyne.Notifier do
  @moduledoc """
  Behaviour for pluggable event notification.

  Implementations receive real-time events about graph changes, trajectory ingestion,
  recall, and maintenance operations.
  """

  require Logger

  @type metadata :: %{
          optional(:repo_id) => String.t() | nil,
          optional(:source_id) => String.t() | nil,
          optional(:trace) => struct() | nil,
          optional(:node_ids) => [String.t()]
        }

  @type event ::
          {:trajectory_ingested, Mnemosyne.IngestionReceipt.t(), metadata()}
          | {:trajectory_ingestion_failed, source_id :: String.t(), reason :: term(), metadata()}
          | {:changeset_applied, Mnemosyne.Graph.Changeset.t(), metadata()}
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
               merged: non_neg_integer(),
               deleted_ids: [String.t()]
             }, metadata()}
          | {:validation_completed,
             %{
               checked: non_neg_integer(),
               penalized: non_neg_integer(),
               orphaned: non_neg_integer()
             }, metadata()}
          | {:repair_completed,
             %{
               checked: non_neg_integer(),
               repaired_nodes: non_neg_integer(),
               dangling_refs: non_neg_integer(),
               orphans_deleted: non_neg_integer(),
               orphan_ids: [String.t()]
             }, metadata()}
          | {:recall_executed, query :: String.t(), results :: term(), metadata()}
          | {:recall_failed, query :: String.t(), reason :: term(), metadata()}
          | {:write_failed, operation :: atom(), reason :: term(), metadata()}
          | {:write_crashed, operation :: atom(), reason :: term(), metadata()}

  @callback notify(repo_id :: String.t(), event()) :: :ok

  @doc """
  Invokes `notifier.notify/2`, isolating and logging exceptions, throws, and exits.

  Always returns `:ok`.
  """
  @spec safe_notify(module(), String.t(), event()) :: :ok
  def safe_notify(notifier, repo_id, event) do
    notifier.notify(repo_id, event)
    :ok
  rescue
    error ->
      Logger.warning("Notifier #{inspect(notifier)} failed: #{Exception.message(error)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("Notifier #{inspect(notifier)} #{kind}: #{inspect(reason)}")
      :ok
  end
end
