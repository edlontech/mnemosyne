defmodule Mnemosyne.Pipeline.SemanticConsolidator do
  @moduledoc """
  Discovers near-duplicate semantic nodes via embedding similarity
  and deletes the lower-scored one using decay-based scoring.

  No LLM calls -- pure embedding similarity + metadata scoring.
  """

  alias Mnemosyne.Graph.Node, as: NodeProtocol
  alias Mnemosyne.Graph.Node.Helpers, as: NodeHelpers
  alias Mnemosyne.Graph.Similarity
  alias Mnemosyne.NodeMetadata

  @default_threshold 0.85

  @doc """
  Finds near-duplicate semantic nodes and deletes the lower-scored one.

  Discovers candidates by walking shared tag neighbors, compares embeddings,
  and condemns the node with the lower decay score when similarity exceeds
  the threshold.

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
      sem_by_id = Map.new(sem_nodes, &{NodeProtocol.id(&1), &1})
      params = semantic_params(config)

      condemned =
        find_all_duplicates(sem_nodes, sem_by_id, all_meta, backend_mod, bs, params, threshold)

      to_delete = MapSet.to_list(condemned)

      with {:ok, bs} <- backend_mod.delete_nodes(to_delete, bs),
           {:ok, bs} <- backend_mod.delete_metadata(to_delete, bs) do
        {:ok, %{deleted: length(to_delete), checked: length(sem_nodes), deleted_ids: to_delete},
         {backend_mod, bs}}
      end
    end
  end

  defp semantic_params(config) do
    get_in(config.value_function, [:params, :semantic]) ||
      %{lambda: 0.01, k: 5, base_floor: 0.3, beta: 1.0}
  end

  defp find_all_duplicates(sem_nodes, sem_by_id, all_meta, backend_mod, bs, params, threshold) do
    Enum.reduce(sem_nodes, MapSet.new(), fn node, condemned ->
      node_id = NodeProtocol.id(node)

      if MapSet.member?(condemned, node_id) do
        condemned
      else
        neighbors = tag_neighbors(node, backend_mod, bs)
        check_neighbors(neighbors, node_id, sem_by_id, all_meta, params, threshold, condemned)
      end
    end)
  end

  defp check_neighbors(neighbors, node_id, sem_by_id, all_meta, params, threshold, condemned) do
    Enum.reduce(neighbors, condemned, fn neighbor_id, acc ->
      if neighbor_id == node_id or MapSet.member?(acc, neighbor_id),
        do: acc,
        else:
          compare_and_condemn(node_id, neighbor_id, sem_by_id, all_meta, params, threshold, acc)
    end)
  end

  defp tag_neighbors(node, backend_mod, bs) do
    linked_ids = node |> NodeHelpers.all_linked_ids() |> MapSet.to_list()
    {:ok, linked_nodes, _bs} = backend_mod.get_linked_nodes(linked_ids, nil, bs)

    tags = Enum.filter(linked_nodes, &(NodeProtocol.node_type(&1) == :tag))

    Enum.flat_map(tags, fn tag ->
      tag_linked_ids = tag |> NodeHelpers.all_linked_ids() |> MapSet.to_list()
      {:ok, tag_neighbors, _bs} = backend_mod.get_linked_nodes(tag_linked_ids, nil, bs)

      tag_neighbors
      |> Enum.filter(&(NodeProtocol.node_type(&1) == :semantic))
      |> Enum.map(&NodeProtocol.id/1)
    end)
    |> Enum.uniq()
  end

  defp compare_and_condemn(id_a, id_b, sem_by_id, all_meta, params, threshold, condemned) do
    node_a = Map.get(sem_by_id, id_a)
    node_b = Map.get(sem_by_id, id_b)

    emb_a = NodeProtocol.embedding(node_a)
    emb_b = NodeProtocol.embedding(node_b)

    if is_nil(emb_a) or is_nil(emb_b) do
      condemned
    else
      similarity = Similarity.cosine_similarity(emb_a, emb_b)

      if similarity > threshold do
        loser = pick_loser(id_a, id_b, all_meta, params)
        MapSet.put(condemned, loser)
      else
        condemned
      end
    end
  end

  defp pick_loser(id_a, id_b, all_meta, params) do
    score_a = decay_score(Map.get(all_meta, id_a), params)
    score_b = decay_score(Map.get(all_meta, id_b), params)

    if score_a >= score_b, do: id_b, else: id_a
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
