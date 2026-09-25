defmodule Mnemosyne.Pipeline.Forget do
  @moduledoc """
  Removes everything a single ingestion produced and frees its `source_id`.

  Looks up the durable ingestion record, deletes the receipt's nodes and their
  metadata, prunes Tags and Intents left without links (same rule as `Decay`),
  and finally deletes the ingestion record so the source can be ingested again.

  Node IDs from the receipt that no longer exist (consolidated or decayed) are
  skipped. Tags and Intents created by this ingestion survive when another
  ingestion has since linked to them. A semantic node from this ingestion that
  absorbed other sources' facts through consolidation is deleted with it; a
  survivor from another source that absorbed this ingestion's facts stays.
  """

  alias Mnemosyne.Errors.Framework.NotFoundError
  alias Mnemosyne.Graph.Node, as: NodeProtocol
  alias Mnemosyne.Pipeline.Decay

  @routing_types [:tag, :intent]

  @type result :: %{source_id: String.t(), deleted_ids: [String.t()]}

  @doc """
  Forgets the ingestion identified by `source_id`.

  ## Options

    * `:backend` - `{module, state}` tuple (required)

  Returns `{:ok, result, {backend_mod, new_state}}` or `{:error, NotFoundError}`
  when no ingestion record exists for `source_id`.
  """
  @spec forget(String.t(), keyword()) ::
          {:ok, result(), {module(), term()}} | {:error, Mnemosyne.Errors.error()}
  def forget(source_id, opts) do
    {backend_mod, bs} = Keyword.fetch!(opts, :backend)

    with {:ok, record, bs} <- backend_mod.get_ingestion(source_id, bs),
         :ok <- ensure_found(record, source_id),
         {:ok, content_ids, bs} <- existing_content_ids(record.receipt.node_ids, backend_mod, bs),
         {:ok, bs} <- backend_mod.delete_nodes(content_ids, bs),
         {:ok, bs} <- backend_mod.delete_metadata(content_ids, bs),
         {:ok, orphan_ids, bs} <- Decay.prune_orphaned_routing_nodes(backend_mod, bs),
         {:ok, bs} <- backend_mod.delete_ingestion(source_id, bs) do
      {:ok, %{source_id: source_id, deleted_ids: content_ids ++ orphan_ids}, {backend_mod, bs}}
    end
  end

  defp ensure_found(nil, source_id),
    do: {:error, NotFoundError.exception(resource: :ingestion, id: source_id)}

  defp ensure_found(_record, _source_id), do: :ok

  # Routing nodes are only removed through orphan pruning so shared tags and
  # intents survive when another ingestion still links to them.
  defp existing_content_ids(node_ids, backend_mod, bs) do
    {ids, bs} =
      Enum.reduce(node_ids, {[], bs}, fn id, {acc, bs} ->
        {:ok, node, bs} = backend_mod.get_node(id, bs)
        if content?(node), do: {[id | acc], bs}, else: {acc, bs}
      end)

    {:ok, Enum.reverse(ids), bs}
  end

  defp content?(nil), do: false
  defp content?(node), do: NodeProtocol.node_type(node) not in @routing_types
end
