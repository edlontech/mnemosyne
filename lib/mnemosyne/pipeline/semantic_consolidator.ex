defmodule Mnemosyne.Pipeline.SemanticConsolidator do
  @moduledoc """
  Discovers near-duplicate semantic nodes via embedding similarity
  and merges the lower-scored one into the higher-scored survivor.

  Transfers all graph connections (tag memberships, sibling links,
  provenance links) from the loser to the winner and merges metadata.
  Cleans up orphaned tags after consolidation.
  """

  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node, as: NodeProtocol
  alias Mnemosyne.Graph.Node.Helpers, as: NodeHelpers
  alias Mnemosyne.Graph.Similarity
  alias Mnemosyne.NodeMetadata

  @default_threshold 0.85

  @doc """
  Finds near-duplicate semantic nodes and merges them.

  Performs pairwise embedding comparison across all semantic nodes,
  transfers the loser's links and metadata to the winner, then
  deletes losers and any orphaned tags.

  ## Options

    * `:backend` - `{module, state}` tuple (required)
    * `:config` - `%Mnemosyne.Config{}` (required)
    * `:threshold` - cosine similarity above which nodes are duplicates (default `#{@default_threshold}`)

  Returns `{:ok, %{deleted: n, checked: n, deleted_ids: [id]}, {backend_mod, new_state}}`.
  """
  @spec consolidate(keyword()) ::
          {:ok,
           %{
             deleted: non_neg_integer(),
             checked: non_neg_integer(),
             deleted_ids: [String.t()]
           }, {module(), term()}}
          | {:error, term()}
  def consolidate(opts) do
    {backend_mod, backend_state} = Keyword.fetch!(opts, :backend)
    config = Keyword.fetch!(opts, :config)
    threshold = Keyword.get(opts, :threshold, @default_threshold)

    with {:ok, sem_nodes, bs} <- backend_mod.get_nodes_by_type([:semantic], backend_state),
         sem_ids = Enum.map(sem_nodes, &NodeProtocol.id/1),
         {:ok, all_meta, bs} <- backend_mod.get_metadata(sem_ids, bs) do
      params = semantic_params(config)

      merge_pairs = find_merge_pairs(sem_nodes, all_meta, params, threshold)
      loser_ids = Enum.map(merge_pairs, &elem(&1, 1))
      merge_map = Map.new(merge_pairs, fn {winner, loser} -> {loser, winner} end)

      {transfer_cs, merged_meta} = build_merge_ops(merge_pairs, merge_map, sem_nodes, all_meta)

      with {:ok, bs} <- apply_if_nonempty(transfer_cs, backend_mod, bs),
           {:ok, bs} <- update_if_nonempty(merged_meta, backend_mod, bs),
           {:ok, bs} <- backend_mod.delete_nodes(loser_ids, bs),
           {:ok, bs} <- backend_mod.delete_metadata(loser_ids, bs),
           {:ok, orphan_ids, bs} <- find_orphaned_tags(backend_mod, bs),
           {:ok, bs} <- delete_if_nonempty(orphan_ids, backend_mod, bs) do
        all_deleted = loser_ids ++ orphan_ids

        {:ok,
         %{deleted: length(all_deleted), checked: length(sem_nodes), deleted_ids: all_deleted},
         {backend_mod, bs}}
      end
    end
  end

  defp semantic_params(config) do
    get_in(config.value_function, [:params, :semantic]) ||
      %{lambda: 0.01, k: 5, base_floor: 0.3, beta: 1.0}
  end

  defp find_merge_pairs(sem_nodes, all_meta, params, threshold) do
    embeddable = Enum.filter(sem_nodes, &(NodeProtocol.embedding(&1) != nil))

    {pairs, _condemned} =
      embeddable
      |> Enum.with_index()
      |> Enum.reduce({[], MapSet.new()}, fn {node_a, idx_a}, acc ->
        scan_candidates(node_a, idx_a, embeddable, all_meta, params, threshold, acc)
      end)

    pairs
  end

  defp scan_candidates(node_a, idx_a, embeddable, all_meta, params, threshold, {pairs, condemned}) do
    id_a = NodeProtocol.id(node_a)

    if MapSet.member?(condemned, id_a) do
      {pairs, condemned}
    else
      embeddable
      |> Enum.drop(idx_a + 1)
      |> Enum.reduce({pairs, condemned}, fn node_b, acc ->
        compare_pair(node_a, node_b, all_meta, params, threshold, acc)
      end)
    end
  end

  defp compare_pair(node_a, node_b, all_meta, params, threshold, {pairs, condemned}) do
    id_b = NodeProtocol.id(node_b)

    if MapSet.member?(condemned, id_b) do
      {pairs, condemned}
    else
      similarity =
        Similarity.cosine_similarity(
          NodeProtocol.embedding(node_a),
          NodeProtocol.embedding(node_b)
        )

      if similarity > threshold do
        id_a = NodeProtocol.id(node_a)
        {winner_id, loser_id} = pick_winner_loser(id_a, id_b, all_meta, params)
        {[{winner_id, loser_id} | pairs], MapSet.put(condemned, loser_id)}
      else
        {pairs, condemned}
      end
    end
  end

  defp pick_winner_loser(id_a, id_b, all_meta, params) do
    score_a = decay_score(Map.get(all_meta, id_a), params)
    score_b = decay_score(Map.get(all_meta, id_b), params)
    if score_a >= score_b, do: {id_a, id_b}, else: {id_b, id_a}
  end

  defp build_merge_ops([], _merge_map, _sem_nodes, _all_meta), do: {Changeset.new(), %{}}

  defp build_merge_ops(merge_pairs, merge_map, sem_nodes, all_meta) do
    nodes_by_id = Map.new(sem_nodes, &{NodeProtocol.id(&1), &1})

    Enum.reduce(merge_pairs, {Changeset.new(), %{}}, fn {winner_id, loser_id},
                                                        {cs, meta_updates} ->
      loser = Map.get(nodes_by_id, loser_id)
      cs = transfer_links(cs, winner_id, loser, merge_map)

      winner_meta =
        Map.get(meta_updates, winner_id) || Map.get(all_meta, winner_id, NodeMetadata.new())

      loser_meta = Map.get(all_meta, loser_id)
      merged = merge_metadata(winner_meta, loser_meta)

      {cs, Map.put(meta_updates, winner_id, merged)}
    end)
  end

  defp transfer_links(cs, winner_id, loser, merge_map) do
    loser_id = NodeProtocol.id(loser)

    loser
    |> NodeProtocol.links()
    |> Enum.reduce(cs, fn {edge_type, linked_ids}, acc ->
      transfer_edge_links(acc, winner_id, loser_id, edge_type, linked_ids, merge_map)
    end)
  end

  defp transfer_edge_links(cs, winner_id, loser_id, edge_type, linked_ids, merge_map) do
    Enum.reduce(linked_ids, cs, fn linked_id, acc ->
      target_id = Map.get(merge_map, linked_id, linked_id)

      if target_id == winner_id or target_id == loser_id,
        do: acc,
        else: Changeset.add_link(acc, winner_id, target_id, edge_type)
    end)
  end

  defp merge_metadata(winner_meta, nil), do: winner_meta

  defp merge_metadata(%NodeMetadata{} = winner, %NodeMetadata{} = loser) do
    %NodeMetadata{
      winner
      | access_count: winner.access_count + loser.access_count,
        cumulative_reward: winner.cumulative_reward + loser.cumulative_reward,
        reward_count: winner.reward_count + loser.reward_count,
        last_accessed_at: latest(winner.last_accessed_at, loser.last_accessed_at),
        created_at: earliest(winner.created_at, loser.created_at)
    }
  end

  defp latest(nil, b), do: b
  defp latest(a, nil), do: a
  defp latest(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)

  defp earliest(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  defp find_orphaned_tags(backend_mod, bs) do
    with {:ok, tags, bs} <- backend_mod.get_nodes_by_type([:tag], bs) do
      orphans =
        tags
        |> Enum.filter(&(NodeHelpers.all_linked_ids(&1) |> MapSet.size() == 0))
        |> Enum.map(&NodeProtocol.id/1)

      {:ok, orphans, bs}
    end
  end

  defp apply_if_nonempty(%Changeset{links: []}, _mod, bs), do: {:ok, bs}
  defp apply_if_nonempty(cs, mod, bs), do: mod.apply_changeset(cs, bs)

  defp update_if_nonempty(meta, _mod, bs) when map_size(meta) == 0, do: {:ok, bs}
  defp update_if_nonempty(meta, mod, bs), do: mod.update_metadata(meta, bs)

  defp delete_if_nonempty([], _mod, bs), do: {:ok, bs}

  defp delete_if_nonempty(ids, mod, bs) do
    {:ok, bs} = mod.delete_nodes(ids, bs)
    mod.delete_metadata(ids, bs)
  end

  defp decay_score(nil, _params), do: 0.0

  defp decay_score(%NodeMetadata{} = meta, params) do
    recency_factor(meta, params) * frequency_factor(meta, params) * reward_factor(meta, params)
  end

  defp recency_factor(%NodeMetadata{} = meta, params) do
    lambda = Map.get(params, :lambda, 0.01)
    reference_time = meta.last_accessed_at || meta.created_at
    hours_since = DateTime.diff(DateTime.utc_now(), reference_time, :second) / 3600.0
    :math.exp(-lambda * hours_since)
  end

  defp frequency_factor(%NodeMetadata{access_count: count}, params) do
    k = Map.get(params, :k, 5)
    base_floor = Map.get(params, :base_floor, 0.3)
    max(base_floor, count / (count + k))
  end

  defp reward_factor(%NodeMetadata{reward_count: 0}, _params), do: 1.0

  defp reward_factor(%NodeMetadata{} = meta, params) do
    beta = Map.get(params, :beta, 1.0)
    avg = NodeMetadata.avg_reward(meta)
    1.0 / (1.0 + :math.exp(-beta * avg))
  end
end
