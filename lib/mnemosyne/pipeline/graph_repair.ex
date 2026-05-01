defmodule Mnemosyne.Pipeline.GraphRepair do
  @moduledoc """
  One-shot maintenance op that scrubs dangling link references from the graph
  and deletes orphaned tags/intents.

  Earlier versions of the DETS persistence layer dropped node rows on delete
  but left back-references intact in surviving rows, so reloading produced a
  graph with edges pointing at missing IDs. This module repairs that drift
  by walking every node, intersecting each link MapSet with the live ID set,
  re-applying the cleaned nodes, and removing routing nodes (tags/intents)
  that have no surviving children.
  """

  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node, as: NodeProtocol
  alias Mnemosyne.Graph.Node.Helpers, as: NodeHelpers

  @all_types [:semantic, :procedural, :episodic, :tag, :intent, :source, :subgoal]
  @routing_types [:tag, :intent]

  @doc """
  Walks every node, drops link IDs that no longer correspond to a live node,
  reapplies the cleaned nodes, then deletes any tag/intent left without
  children.

  ## Options

    * `:backend` - `{module, state}` tuple (required)

  Returns `{:ok, summary, {backend_mod, new_state}}` where `summary` is a map
  with `:checked`, `:repaired_nodes`, `:dangling_refs`, `:orphans_deleted`,
  and `:orphan_ids`.
  """
  @spec repair(keyword()) ::
          {:ok,
           %{
             checked: non_neg_integer(),
             repaired_nodes: non_neg_integer(),
             dangling_refs: non_neg_integer(),
             orphans_deleted: non_neg_integer(),
             orphan_ids: [String.t()]
           }, {module(), term()}}
          | {:error, term()}
  def repair(opts) do
    {backend_mod, backend_state} = Keyword.fetch!(opts, :backend)

    with {:ok, all_nodes, bs} <- backend_mod.get_nodes_by_type(@all_types, backend_state) do
      valid_ids = MapSet.new(all_nodes, &NodeProtocol.id/1)

      {repaired_cs, dangling_count, repaired_count} = build_repair_changeset(all_nodes, valid_ids)

      with {:ok, bs} <- apply_if_nonempty(repaired_cs, backend_mod, bs),
           {:ok, orphan_ids, bs} <- find_orphans(backend_mod, bs),
           {:ok, bs} <- delete_if_nonempty(orphan_ids, backend_mod, bs) do
        summary = %{
          checked: length(all_nodes),
          repaired_nodes: repaired_count,
          dangling_refs: dangling_count,
          orphans_deleted: length(orphan_ids),
          orphan_ids: orphan_ids
        }

        {:ok, summary, {backend_mod, bs}}
      end
    end
  end

  defp build_repair_changeset(nodes, valid_ids) do
    Enum.reduce(nodes, {Changeset.new(), 0, 0}, fn node, {cs, dangling_acc, repaired_acc} ->
      links = NodeProtocol.links(node)
      {cleaned_links, removed} = strip_links(links, valid_ids)

      if removed == 0 do
        {cs, dangling_acc, repaired_acc}
      else
        updated = %{node | links: cleaned_links}
        {Changeset.add_node(cs, updated), dangling_acc + removed, repaired_acc + 1}
      end
    end)
  end

  defp strip_links(links, valid_ids) do
    Enum.reduce(links, {%{}, 0}, fn {type, ids}, {acc, removed} ->
      kept = MapSet.intersection(ids, valid_ids)
      delta = MapSet.size(ids) - MapSet.size(kept)
      {Map.put(acc, type, kept), removed + delta}
    end)
  end

  defp find_orphans(backend_mod, bs) do
    with {:ok, routing, bs} <- backend_mod.get_nodes_by_type(@routing_types, bs) do
      orphans =
        routing
        |> Enum.filter(&(NodeHelpers.all_linked_ids(&1) |> MapSet.size() == 0))
        |> Enum.map(&NodeProtocol.id/1)

      {:ok, orphans, bs}
    end
  end

  defp apply_if_nonempty(%Changeset{additions: []}, _mod, bs), do: {:ok, bs}
  defp apply_if_nonempty(cs, mod, bs), do: mod.apply_changeset(cs, bs)

  defp delete_if_nonempty([], _mod, bs), do: {:ok, bs}

  defp delete_if_nonempty(ids, mod, bs) do
    with {:ok, bs} <- mod.delete_nodes(ids, bs) do
      mod.delete_metadata(ids, bs)
    end
  end
end
