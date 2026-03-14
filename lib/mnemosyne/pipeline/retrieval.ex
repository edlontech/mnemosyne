defmodule Mnemosyne.Pipeline.Retrieval do
  @moduledoc """
  Multi-hop graph retrieval pipeline.

  Classifies a query by memory mode, generates retrieval tags,
  embeds them, scores candidate nodes via value functions,
  and performs multi-hop traversal to expand and re-rank results.
  """

  require Logger

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.Graph.Node, as: NodeProtocol
  alias Mnemosyne.Graph.Similarity
  alias Mnemosyne.Pipeline.Prompts.GetMode
  alias Mnemosyne.Pipeline.Prompts.GetPlan

  use TypedStruct

  typedstruct module: Result do
    @moduledoc """
    Result of a retrieval operation containing the classified mode,
    generated tags, and scored candidate nodes partitioned by type.
    """

    field :mode, atom()
    field :tags, [String.t()]
    field :candidates, %{atom() => [{struct(), float()}]}, default: %{}
  end

  @default_max_hops 2
  @max_candidates_per_hop 100
  @provenance_decay 0.5

  @doc """
  Retrieves relevant memory nodes from the graph for the given query.

  Options:
    - `:llm` (required) - LLM module implementing the LLM behaviour
    - `:embedding` (required) - Embedding module implementing the Embedding behaviour
    - `:backend` (required) - Tuple of `{module, state}` implementing GraphBackend
    - `:value_function` (required) - Map with `:module` (ValueFunction impl) and `:params` (per-type params)
    - `:llm_opts` - Additional LLM options (default: [])
    - `:config` - Config struct for per-step model overrides
    - `:max_hops` - Maximum traversal hops (default: 2)
  """
  @spec retrieve(String.t(), keyword()) :: {:ok, Result.t()} | {:error, Mnemosyne.Errors.error()}
  def retrieve(query, opts) do
    Mnemosyne.Telemetry.span([:retrieval, :retrieve], %{}, fn ->
      llm = Keyword.fetch!(opts, :llm)
      embedding = Keyword.fetch!(opts, :embedding)
      backend = Keyword.fetch!(opts, :backend)
      value_fns = Keyword.fetch!(opts, :value_function)
      llm_opts = Keyword.get(opts, :llm_opts, [])
      config = Keyword.get(opts, :config)
      max_hops = Keyword.get(opts, :max_hops, @default_max_hops)

      with {:ok, mode} <- classify_mode(query, llm, llm_opts, config),
           {:ok, tags} <- generate_plan(query, mode, llm, llm_opts, config),
           {:ok, %Embedding.Response{vectors: tag_vectors}} <-
             embedding.embed_batch(tags, Config.embedding_opts(config)),
           {:ok, %Embedding.Response{vectors: [query_vector]}} <-
             embedding.embed(query, Config.embedding_opts(config)) do
        Logger.debug("retrieval mode classified as #{mode}")

        target_types = types_for_mode(mode)

        candidates =
          hop_0(backend, query_vector, tag_vectors, target_types, value_fns)
          |> multi_hop(backend, query_vector, value_fns, max_hops, mode)
          |> maybe_expand_provenance(backend, mode)
          |> partition_by_type()

        total_candidates =
          candidates |> Map.values() |> List.flatten() |> length()

        {{:ok, %Result{mode: mode, tags: tags, candidates: candidates}},
         %{candidates_found: total_candidates}}
      else
        error -> {error, %{}}
      end
    end)
  end

  defp classify_mode(query, llm, llm_opts, config) do
    messages = GetMode.build_messages(%{query: query})

    with {:ok, %{content: content}} <-
           llm.chat(messages, Config.llm_opts(config, :get_mode, llm_opts)) do
      GetMode.parse_response(content)
    end
  end

  defp generate_plan(query, mode, llm, llm_opts, config) do
    messages = GetPlan.build_messages(%{query: query, mode: mode})

    with {:ok, %{content: content}} <-
           llm.chat(messages, Config.llm_opts(config, :get_plan, llm_opts)) do
      GetPlan.parse_response(content)
    end
  end

  defp types_for_mode(:episodic), do: [:episodic, :subgoal]
  defp types_for_mode(:semantic), do: [:semantic]
  defp types_for_mode(:procedural), do: [:procedural]
  defp types_for_mode(:mixed), do: [:episodic, :semantic, :procedural, :subgoal]

  defp routing_types_for_mode(:semantic), do: [:tag]
  defp routing_types_for_mode(:procedural), do: [:intent]
  defp routing_types_for_mode(:mixed), do: [:tag, :intent]
  defp routing_types_for_mode(:episodic), do: [:tag]

  defp hop_0(backend, query_vector, tag_vectors, target_types, value_fns) do
    {mod, bs} = backend

    {:ok, candidates, _bs} =
      mod.find_candidates(target_types, query_vector, tag_vectors, value_fns, [], bs)

    candidates
  end

  defp multi_hop(candidates, _backend, _query_vector, _value_fns, 0, _mode), do: candidates

  defp multi_hop(candidates, backend, query_vector, value_fns, hops_remaining, mode) do
    seen_ids = MapSet.new(candidates, fn {node, _} -> NodeProtocol.id(node) end)
    routing_types = routing_types_for_mode(mode)
    new_nodes = expand_through_routing_nodes(candidates, backend, seen_ids, routing_types)

    vf_module = Map.get(value_fns, :module, Mnemosyne.ValueFunction.Default)

    scored =
      Enum.map(new_nodes, fn node ->
        emb = NodeProtocol.embedding(node)
        relevance = if emb, do: Similarity.cosine_similarity(query_vector, emb), else: 0.0
        type = NodeProtocol.node_type(node)
        params = get_in(value_fns, [:params, type]) || %{}
        score = vf_module.score(relevance, node, nil, params)
        {node, score}
      end)

    merged =
      (candidates ++ scored)
      |> Enum.uniq_by(fn {node, _} -> NodeProtocol.id(node) end)
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.take(@max_candidates_per_hop)

    multi_hop(merged, backend, query_vector, value_fns, hops_remaining - 1, mode)
  end

  @doc false
  def expand_through_routing_nodes(candidates, backend, seen_ids, routing_types) do
    {mod, bs} = backend

    candidate_link_ids =
      candidates
      |> Enum.flat_map(fn {node, _} -> NodeProtocol.links(node) |> MapSet.to_list() end)
      |> Enum.uniq()

    {:ok, linked_nodes, _bs} = mod.get_linked_nodes(candidate_link_ids, bs)

    routing_nodes =
      Enum.filter(linked_nodes, fn node ->
        NodeProtocol.node_type(node) in routing_types
      end)

    sibling_ids =
      routing_nodes
      |> Enum.flat_map(fn node -> NodeProtocol.links(node) |> MapSet.to_list() end)
      |> Enum.reject(&MapSet.member?(seen_ids, &1))
      |> Enum.uniq()

    {:ok, siblings, _bs} = mod.get_linked_nodes(sibling_ids, bs)

    Enum.reject(siblings, fn node ->
      NodeProtocol.node_type(node) in routing_types
    end)
  end

  defp maybe_expand_provenance(candidates, backend, :episodic) do
    {mod, bs} = backend
    candidate_ids = MapSet.new(candidates, fn {node, _} -> NodeProtocol.id(node) end)

    episodic_link_ids =
      candidates
      |> Enum.filter(fn {node, _} -> NodeProtocol.node_type(node) == :episodic end)
      |> Enum.flat_map(fn {node, _score} -> NodeProtocol.links(node) |> MapSet.to_list() end)
      |> Enum.reject(&MapSet.member?(candidate_ids, &1))
      |> Enum.uniq()

    {:ok, linked_nodes, _bs} = mod.get_linked_nodes(episodic_link_ids, bs)

    source_nodes =
      linked_nodes
      |> Enum.filter(&(NodeProtocol.node_type(&1) == :source))
      |> Enum.map(fn source ->
        parent_score =
          candidates
          |> Enum.filter(fn {node, _} ->
            NodeProtocol.node_type(node) == :episodic and
              MapSet.member?(NodeProtocol.links(node), NodeProtocol.id(source))
          end)
          |> Enum.map(fn {_, score} -> score end)
          |> Enum.max(fn -> 0.0 end)

        {source, parent_score * @provenance_decay}
      end)

    candidates ++ source_nodes
  end

  defp maybe_expand_provenance(candidates, _backend, _mode), do: candidates

  defp partition_by_type(candidates) do
    Enum.group_by(
      candidates,
      fn {node, _score} -> NodeProtocol.node_type(node) end
    )
  end
end
