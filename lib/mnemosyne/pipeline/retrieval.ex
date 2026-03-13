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
  alias Mnemosyne.Graph
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

  @type value_functions :: %{atom() => module()}

  @default_max_hops 2
  @max_candidates_per_hop 100
  @provenance_decay 0.5

  @doc """
  Retrieves relevant memory nodes from the graph for the given query.

  Options:
    - `:llm` (required) - LLM module implementing the LLM behaviour
    - `:embedding` (required) - Embedding module implementing the Embedding behaviour
    - `:graph` (required) - The knowledge graph to search
    - `:value_functions` (required) - Map of node type atoms to ValueFunction modules
    - `:llm_opts` - Additional LLM options (default: [])
    - `:config` - Config struct for per-step model overrides
    - `:max_hops` - Maximum traversal hops (default: 2)
  """
  @spec retrieve(String.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def retrieve(query, opts) do
    Mnemosyne.Telemetry.span([:retrieval, :retrieve], %{}, fn ->
      llm = Keyword.fetch!(opts, :llm)
      embedding = Keyword.fetch!(opts, :embedding)
      graph = Keyword.fetch!(opts, :graph)
      value_fns = Keyword.fetch!(opts, :value_functions)
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
          hop_0(graph, query_vector, tag_vectors, target_types, value_fns)
          |> multi_hop(graph, query_vector, value_fns, max_hops)
          |> maybe_expand_provenance(graph, mode)
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
  defp types_for_mode(:semantic), do: [:semantic, :tag]
  defp types_for_mode(:procedural), do: [:procedural, :subgoal]
  defp types_for_mode(:mixed), do: [:episodic, :semantic, :procedural, :subgoal, :tag]

  defp hop_0(graph, query_vector, tag_vectors, target_types, value_fns) do
    target_types
    |> Enum.flat_map(&score_type(graph, &1, query_vector, tag_vectors, value_fns))
    |> Enum.uniq_by(fn {node, _score} -> NodeProtocol.id(node) end)
  end

  defp score_type(graph, type, query_vector, tag_vectors, value_fns) do
    nodes = Graph.nodes_by_type(graph, type)
    value_fn = Map.get(value_fns, type)

    candidates = Enum.map(nodes, &score_node(&1, query_vector, tag_vectors, value_fn))

    threshold = if value_fn, do: value_fn.threshold(), else: 0.0
    k = if value_fn, do: value_fn.top_k(), else: 20

    candidates
    |> Enum.filter(fn {_node, score} -> score >= threshold end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(k)
  end

  defp score_node(node, query_vector, tag_vectors, value_fn) do
    emb = NodeProtocol.embedding(node)
    relevance = compute_relevance(emb, query_vector, tag_vectors)
    score = if value_fn, do: value_fn.score(relevance, node), else: relevance
    {node, score}
  end

  defp compute_relevance(nil, _query_vector, _tag_vectors), do: 0.0

  defp compute_relevance(emb, query_vector, tag_vectors) do
    query_sim = Similarity.cosine_similarity(query_vector, emb)

    tag_sim =
      tag_vectors
      |> Enum.map(&Similarity.cosine_similarity(&1, emb))
      |> Enum.max(fn -> 0.0 end)

    max(query_sim, tag_sim) |> max(0.0)
  end

  defp multi_hop(candidates, _graph, _query_vector, _value_fns, 0), do: candidates

  defp multi_hop(candidates, graph, query_vector, value_fns, hops_remaining) do
    candidate_ids = MapSet.new(candidates, fn {node, _} -> NodeProtocol.id(node) end)

    neighbors =
      candidates
      |> Enum.flat_map(fn {node, _score} ->
        node
        |> NodeProtocol.links()
        |> Enum.reject(&MapSet.member?(candidate_ids, &1))
        |> Enum.map(&Graph.get_node(graph, &1))
        |> Enum.reject(&is_nil/1)
      end)
      |> Enum.uniq_by(&NodeProtocol.id/1)

    scored_neighbors =
      Enum.map(neighbors, fn node ->
        emb = NodeProtocol.embedding(node)
        relevance = if emb, do: Similarity.cosine_similarity(query_vector, emb), else: 0.0
        type = NodeProtocol.node_type(node)
        value_fn = Map.get(value_fns, type)
        score = if value_fn, do: value_fn.score(relevance, node), else: relevance
        {node, score}
      end)

    merged =
      (candidates ++ scored_neighbors)
      |> Enum.uniq_by(fn {node, _} -> NodeProtocol.id(node) end)
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.take(@max_candidates_per_hop)

    multi_hop(merged, graph, query_vector, value_fns, hops_remaining - 1)
  end

  defp maybe_expand_provenance(candidates, graph, :episodic) do
    candidate_ids = MapSet.new(candidates, fn {node, _} -> NodeProtocol.id(node) end)

    source_nodes =
      candidates
      |> Enum.filter(fn {node, _} -> NodeProtocol.node_type(node) == :episodic end)
      |> Enum.flat_map(fn {node, score} ->
        node
        |> NodeProtocol.links()
        |> Enum.map(&Graph.get_node(graph, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(&(NodeProtocol.node_type(&1) == :source))
        |> Enum.reject(&MapSet.member?(candidate_ids, NodeProtocol.id(&1)))
        |> Enum.map(&{&1, score * @provenance_decay})
      end)

    candidates ++ source_nodes
  end

  defp maybe_expand_provenance(candidates, _graph, _mode), do: candidates

  defp partition_by_type(candidates) do
    Enum.group_by(
      candidates,
      fn {node, _score} -> NodeProtocol.node_type(node) end
    )
  end
end
