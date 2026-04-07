defmodule Mnemosyne.Pipeline.EpisodicValidation do
  @moduledoc """
  Maintenance module that validates episodic grounding of abstract nodes.

  Walks the provenance chain from semantic/procedural nodes through
  episodic nodes to source nodes and penalizes nodes whose source
  embeddings diverge significantly from the abstract node's embedding.
  Orphaned nodes (no provenance links) receive a larger penalty.
  """

  alias Mnemosyne.Graph.Node, as: NodeProtocol
  alias Mnemosyne.Graph.Similarity
  alias Mnemosyne.NodeMetadata

  @default_validation_threshold 0.3
  @default_orphan_penalty 0.3
  @default_weak_grounding_penalty 0.1

  @doc """
  Validates episodic grounding of semantic and procedural nodes.

  ## Options

    * `:backend` - `{module, state}` tuple (required)
    * `:config` - `%Mnemosyne.Config{}` (required)

  Returns `{:ok, stats, {backend_mod, new_state}}` where stats contains
  `:checked`, `:penalized`, `:orphaned`, and `:grounded` counts.
  """
  @spec validate(keyword()) :: {:ok, map(), {module(), term()}} | {:error, term()}
  def validate(opts) do
    {backend_mod, bs} = Keyword.fetch!(opts, :backend)
    config = Keyword.fetch!(opts, :config)

    threshold = get_param(config, :validation_threshold, @default_validation_threshold)
    orphan_penalty = get_param(config, :orphan_penalty, @default_orphan_penalty)
    weak_penalty = get_param(config, :weak_grounding_penalty, @default_weak_grounding_penalty)

    with {:ok, abstract_nodes, bs} <- backend_mod.get_nodes_by_type([:semantic, :procedural], bs),
         node_ids = Enum.map(abstract_nodes, &NodeProtocol.id/1),
         {:ok, all_metadata, bs} <- backend_mod.get_metadata(node_ids, bs) do
      {updates, stats} =
        Enum.reduce(
          abstract_nodes,
          {%{}, %{penalized: 0, orphaned: 0, grounded: 0}},
          fn node, acc ->
            source_embeddings = collect_source_embeddings(node, backend_mod, bs)

            {penalty, stat_key} =
              compute_penalty(
                source_embeddings,
                NodeProtocol.embedding(node),
                threshold,
                orphan_penalty,
                weak_penalty
              )

            apply_penalty(NodeProtocol.id(node), penalty, stat_key, all_metadata, acc)
          end
        )

      bs =
        if map_size(updates) > 0 do
          {:ok, bs} = backend_mod.update_metadata(updates, bs)
          bs
        else
          bs
        end

      {:ok, Map.put(stats, :checked, length(abstract_nodes)), {backend_mod, bs}}
    end
  end

  defp apply_penalty(_node_id, penalty, stat_key, _all_metadata, {meta_acc, stats_acc})
       when penalty == 0.0 do
    {meta_acc, Map.update!(stats_acc, stat_key, &(&1 + 1))}
  end

  defp apply_penalty(node_id, penalty, stat_key, all_metadata, {meta_acc, stats_acc}) do
    current_meta = Map.get(all_metadata, node_id, NodeMetadata.new())

    updated_meta = %{
      current_meta
      | cumulative_reward: max(0.0, current_meta.cumulative_reward - penalty)
    }

    {Map.put(meta_acc, node_id, updated_meta), Map.update!(stats_acc, stat_key, &(&1 + 1))}
  end

  defp compute_penalty([], _node_embedding, _threshold, orphan_penalty, _weak_penalty) do
    {orphan_penalty, :orphaned}
  end

  defp compute_penalty(_source_embeddings, nil, _threshold, _orphan_penalty, _weak_penalty) do
    {0.0, :grounded}
  end

  defp compute_penalty(
         source_embeddings,
         node_embedding,
         threshold,
         _orphan_penalty,
         weak_penalty
       ) do
    max_sim =
      source_embeddings
      |> Enum.map(&Similarity.cosine_similarity(node_embedding, &1))
      |> Enum.filter(&is_float/1)
      |> Enum.max(fn -> 0.0 end)

    if max_sim < threshold, do: {weak_penalty, :penalized}, else: {0.0, :grounded}
  end

  defp collect_source_embeddings(node, backend_mod, bs) do
    episodic_ids = NodeProtocol.links(node, :provenance) |> MapSet.to_list()

    case backend_mod.get_linked_nodes(episodic_ids, nil, bs) do
      {:ok, linked_nodes, _bs} ->
        source_ids =
          linked_nodes
          |> Enum.filter(&(NodeProtocol.node_type(&1) == :episodic))
          |> Enum.flat_map(&(NodeProtocol.links(&1, :provenance) |> MapSet.to_list()))

        case backend_mod.get_linked_nodes(source_ids, nil, bs) do
          {:ok, source_nodes, _bs} ->
            source_nodes
            |> Enum.filter(&(NodeProtocol.node_type(&1) == :source))
            |> Enum.map(&NodeProtocol.embedding/1)
            |> Enum.reject(&is_nil/1)

          _ ->
            []
        end

      _ ->
        []
    end
  end

  defp get_param(config, key, default) do
    case Map.get(config, :episodic_validation) do
      nil -> default
      params -> Map.get(params, key, default)
    end
  end
end
