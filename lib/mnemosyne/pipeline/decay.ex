defmodule Mnemosyne.Pipeline.Decay do
  @moduledoc """
  Maintenance module that prunes low-utility nodes from the knowledge graph.

  Scores all nodes of specified types using a relevance-free decay formula
  (recency * frequency * reward) and deletes those scoring below a threshold.
  After deletion, cleans up orphaned Tags and Intents that have no remaining
  children.
  """

  alias Mnemosyne.Config
  alias Mnemosyne.Graph.Node, as: NodeProtocol
  alias Mnemosyne.NodeMetadata

  @default_threshold 0.1
  @default_types [:semantic, :procedural]

  @doc """
  Scores all nodes of the given types and deletes those below the threshold.

  ## Options

    * `:backend` - `{module, state}` tuple (required)
    * `:config` - `%Mnemosyne.Config{}` (required)
    * `:threshold` - minimum score to survive (default `#{@default_threshold}`)
    * `:node_types` - list of node type atoms (default `#{inspect(@default_types)}`)

  Returns `{:ok, %{deleted: n, checked: n, deleted_ids: [id]}, {backend_mod, new_state}}`.
  """
  @spec decay(keyword()) ::
          {:ok,
           %{
             deleted: non_neg_integer(),
             checked: non_neg_integer(),
             deleted_ids: [String.t()]
           }, {module(), term()}}
          | {:error, term()}
  def decay(opts) do
    {backend_mod, backend_state} = Keyword.fetch!(opts, :backend)
    config = Keyword.fetch!(opts, :config)
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    node_types = Keyword.get(opts, :node_types, @default_types)

    with {:ok, nodes, bs} <- backend_mod.get_nodes_by_type(node_types, backend_state),
         node_ids = Enum.map(nodes, &NodeProtocol.id/1),
         {:ok, all_meta, bs} <- backend_mod.get_metadata(node_ids, bs) do
      to_delete =
        nodes
        |> Enum.filter(fn node ->
          id = NodeProtocol.id(node)
          type = NodeProtocol.node_type(node)
          meta = Map.get(all_meta, id)
          score = decay_score(meta, type, config)
          not is_float(score) or score < threshold
        end)
        |> Enum.map(&NodeProtocol.id/1)

      with {:ok, bs} <- backend_mod.delete_nodes(to_delete, bs),
           {:ok, bs} <- backend_mod.delete_metadata(to_delete, bs),
           {:ok, orphan_ids, bs} <- find_orphaned_routing_nodes(backend_mod, bs),
           {:ok, bs} <- backend_mod.delete_nodes(orphan_ids, bs),
           {:ok, bs} <- backend_mod.delete_metadata(orphan_ids, bs) do
        all_deleted = to_delete ++ orphan_ids

        {:ok, %{deleted: length(all_deleted), checked: length(nodes), deleted_ids: all_deleted},
         {backend_mod, bs}}
      end
    end
  end

  defp find_orphaned_routing_nodes(backend_mod, bs) do
    with {:ok, routing_nodes, bs} <- backend_mod.get_nodes_by_type([:tag, :intent], bs) do
      orphans =
        routing_nodes
        |> Enum.filter(&(MapSet.size(NodeProtocol.links(&1)) == 0))
        |> Enum.map(&NodeProtocol.id/1)

      {:ok, orphans, bs}
    end
  end

  defp decay_score(nil, _type, _config), do: 0.0

  defp decay_score(%NodeMetadata{} = meta, type, config) do
    params = Config.resolve_value_function(config, type)
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
