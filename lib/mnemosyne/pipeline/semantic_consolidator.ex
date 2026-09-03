defmodule Mnemosyne.Pipeline.SemanticConsolidator do
  @moduledoc """
  Discovers near-duplicate semantic nodes through the tag-induced
  projection (nodes sharing at least one tag) and merges them via an
  LLM that synthesizes a combined statement.

  For each semantic node, the most similar tag-neighbor above the
  threshold is considered for merging. The LLM classifies the pair:
  same-fact updates and well-merging topics are merged into the
  higher-scored survivor, whose proposition is replaced by the merged
  statement and re-embedded, while the other node's links and metadata
  transfer to the survivor before it is deleted. Weakly related pairs
  are kept separate to avoid stitching unrelated facts together.
  Cleans up orphaned tags after consolidation.
  """

  require Logger

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node, as: NodeProtocol
  alias Mnemosyne.Graph.Node.Helpers, as: NodeHelpers
  alias Mnemosyne.Graph.Similarity
  alias Mnemosyne.LLM
  alias Mnemosyne.NodeMetadata
  alias Mnemosyne.Pipeline.Prompts.MergeSemantic
  alias Mnemosyne.ValueFunction

  @default_threshold 0.7

  @doc """
  Finds near-duplicate semantic nodes via their shared tags and merges them.

  For each semantic node, candidates are the semantic nodes attached to at
  least one of its tags. The most similar candidate above the threshold is
  submitted to the LLM, which either synthesizes a merged statement (the
  pair is consolidated into the higher-scored node) or rejects the merge
  (both nodes are kept).

  ## Options

    * `:backend` - `{module, state}` tuple (required)
    * `:config` - `%Mnemosyne.Config{}` (required)
    * `:llm` - LLM adapter module (required)
    * `:embedding` - embedding adapter module (required)
    * `:threshold` - cosine similarity above which a pair is submitted for merging (default `#{@default_threshold}`)

  Returns `{:ok, %{deleted: n, checked: n, merged: n, deleted_ids: [id]}, {backend_mod, new_state}}`.
  """
  @spec consolidate(keyword()) ::
          {:ok,
           %{
             deleted: non_neg_integer(),
             checked: non_neg_integer(),
             merged: non_neg_integer(),
             deleted_ids: [String.t()]
           }, {module(), term()}}
          | {:error, term()}
  def consolidate(opts) do
    {backend_mod, backend_state} = Keyword.fetch!(opts, :backend)
    config = Keyword.fetch!(opts, :config)
    llm = Keyword.fetch!(opts, :llm)
    embedding = Keyword.fetch!(opts, :embedding)
    threshold = Keyword.get(opts, :threshold, @default_threshold)

    with {:ok, sem_nodes, bs} <- backend_mod.get_nodes_by_type([:semantic], backend_state),
         sem_ids = Enum.map(sem_nodes, &NodeProtocol.id/1),
         {:ok, all_meta, bs} <- backend_mod.get_metadata(sem_ids, bs) do
      params = semantic_params(config)

      candidate_pairs = find_candidate_pairs(sem_nodes, threshold)

      {merge_cs, meta_updates, loser_ids, merged_count} =
        decide_merges(candidate_pairs, sem_nodes, all_meta, params, llm, embedding, config)

      with {:ok, bs} <- apply_if_nonempty(merge_cs, backend_mod, bs),
           {:ok, bs} <- update_if_nonempty(meta_updates, backend_mod, bs),
           {:ok, bs} <- backend_mod.delete_nodes(loser_ids, bs),
           {:ok, bs} <- backend_mod.delete_metadata(loser_ids, bs),
           {:ok, orphan_ids, bs} <- find_orphaned_tags(backend_mod, bs),
           {:ok, bs} <- delete_if_nonempty(orphan_ids, backend_mod, bs) do
        all_deleted = loser_ids ++ orphan_ids

        {:ok,
         %{
           deleted: length(all_deleted),
           checked: length(sem_nodes),
           merged: merged_count,
           deleted_ids: all_deleted
         }, {backend_mod, bs}}
      end
    end
  end

  defp semantic_params(config) do
    get_in(config.value_function, [:params, :semantic]) ||
      %{lambda: ValueFunction.default_recency_lambda(), k: 5, base_floor: 0.3, beta: 1.0}
  end

  # Tag-induced projection: for each semantic node, the merge candidates
  # are the semantic nodes attached to at least one of its tags. The most
  # similar candidate above the threshold forms a pair (top-1 per node).
  defp find_candidate_pairs(sem_nodes, threshold) do
    embeddable = Enum.filter(sem_nodes, &(NodeProtocol.embedding(&1) != nil))
    nodes_by_id = Map.new(embeddable, &{NodeProtocol.id(&1), &1})

    tag_to_sems =
      Enum.reduce(embeddable, %{}, fn node, acc ->
        id = NodeProtocol.id(node)

        node
        |> NodeProtocol.links(:membership)
        |> Enum.reduce(acc, fn tag_id, inner ->
          Map.update(inner, tag_id, [id], &[id | &1])
        end)
      end)

    {pairs, _paired} =
      Enum.reduce(embeddable, {[], MapSet.new()}, fn node, acc ->
        pair_node(node, nodes_by_id, tag_to_sems, threshold, acc)
      end)

    Enum.reverse(pairs)
  end

  defp pair_node(node, nodes_by_id, tag_to_sems, threshold, {pairs, paired}) do
    id = NodeProtocol.id(node)

    with false <- MapSet.member?(paired, id),
         other_id when is_binary(other_id) <-
           best_tag_neighbor(node, nodes_by_id, tag_to_sems, paired, threshold) do
      {[{id, other_id} | pairs], paired |> MapSet.put(id) |> MapSet.put(other_id)}
    else
      _ -> {pairs, paired}
    end
  end

  defp best_tag_neighbor(node, nodes_by_id, tag_to_sems, paired, threshold) do
    id = NodeProtocol.id(node)
    embedding = NodeProtocol.embedding(node)

    node
    |> NodeProtocol.links(:membership)
    |> Enum.flat_map(&Map.get(tag_to_sems, &1, []))
    |> Enum.uniq()
    |> Enum.reject(&(&1 == id or MapSet.member?(paired, &1)))
    |> Enum.map(fn neighbor_id ->
      neighbor = Map.fetch!(nodes_by_id, neighbor_id)
      {neighbor_id, Similarity.cosine_similarity(embedding, NodeProtocol.embedding(neighbor))}
    end)
    |> Enum.filter(fn {_id, sim} -> is_float(sim) and sim > threshold end)
    |> Enum.max_by(&elem(&1, 1), fn -> nil end)
    |> case do
      nil -> nil
      {neighbor_id, _sim} -> neighbor_id
    end
  end

  defp decide_merges(candidate_pairs, sem_nodes, all_meta, params, llm, embedding, config) do
    nodes_by_id = Map.new(sem_nodes, &{NodeProtocol.id(&1), &1})

    {merges, merge_map} =
      Enum.reduce(candidate_pairs, {[], %{}}, fn {id_a, id_b}, {merges, merge_map} ->
        node_a = Map.fetch!(nodes_by_id, id_a)
        node_b = Map.fetch!(nodes_by_id, id_b)

        case llm_merge_decision(node_a, node_b, all_meta, llm, embedding, config) do
          {:merge, statement, statement_embedding} ->
            {winner_id, loser_id} = pick_winner_loser(id_a, id_b, all_meta, params)
            winner = Map.fetch!(nodes_by_id, winner_id)
            survivor = %{winner | proposition: statement, embedding: statement_embedding}

            {[{survivor, winner_id, loser_id} | merges], Map.put(merge_map, loser_id, winner_id)}

          :keep_both ->
            {merges, merge_map}
        end
      end)

    build_merge_ops(Enum.reverse(merges), merge_map, nodes_by_id, all_meta)
  end

  defp llm_merge_decision(node_a, node_b, all_meta, llm, embedding, config) do
    {earlier, later} = order_by_creation(node_a, node_b, all_meta)

    messages =
      MergeSemantic.build_messages(%{
        earlier: earlier.proposition,
        later: later.proposition,
        overlay: Config.resolve_overlay(config, :merge_semantic)
      })

    llm_opts = Config.llm_opts(config, :merge_semantic, [])

    with {:ok, %LLM.Response{content: content}} <-
           llm.chat_structured(messages, MergeSemantic.schema(), llm_opts),
         {:ok, {:merge, statement}} <- MergeSemantic.parse_response(content),
         {:ok, %Embedding.Response{vectors: [vector | _]}} <-
           embedding.embed(statement, Config.embedding_opts(config)) do
      {:merge, statement, vector}
    else
      {:ok, :keep_both} ->
        :keep_both

      error ->
        Logger.warning("semantic merge failed, keeping both nodes: #{inspect(error)}")
        :keep_both
    end
  end

  defp order_by_creation(node_a, node_b, all_meta) do
    created_a = creation_time(node_a, all_meta)
    created_b = creation_time(node_b, all_meta)

    if DateTime.compare(created_a, created_b) == :gt do
      {node_b, node_a}
    else
      {node_a, node_b}
    end
  end

  defp creation_time(node, all_meta) do
    case Map.get(all_meta, NodeProtocol.id(node)) do
      %NodeMetadata{created_at: %DateTime{} = dt} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp pick_winner_loser(id_a, id_b, all_meta, params) do
    score_a = decay_score(Map.get(all_meta, id_a), params)
    score_b = decay_score(Map.get(all_meta, id_b), params)
    if score_a >= score_b, do: {id_a, id_b}, else: {id_b, id_a}
  end

  defp build_merge_ops(merges, merge_map, nodes_by_id, all_meta) do
    {cs, meta_updates} =
      Enum.reduce(merges, {Changeset.new(), %{}}, fn {survivor, winner_id, loser_id},
                                                     {cs, meta_updates} ->
        loser = Map.fetch!(nodes_by_id, loser_id)

        cs =
          cs
          |> Changeset.add_node(survivor)
          |> transfer_links(winner_id, loser, merge_map)

        winner_meta =
          Map.get(meta_updates, winner_id) || Map.get(all_meta, winner_id, NodeMetadata.new())

        merged = merge_metadata(winner_meta, Map.get(all_meta, loser_id))

        {cs, Map.put(meta_updates, winner_id, merged)}
      end)

    loser_ids = Enum.map(merges, fn {_survivor, _winner_id, loser_id} -> loser_id end)
    {cs, meta_updates, loser_ids, length(merges)}
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

  defp apply_if_nonempty(%Changeset{additions: [], links: []}, _mod, bs), do: {:ok, bs}
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
    lambda = Map.get(params, :lambda, ValueFunction.default_recency_lambda())
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
