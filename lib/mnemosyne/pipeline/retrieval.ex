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
  alias Mnemosyne.Notifier.Trace.Recall, as: RecallTrace
  alias Mnemosyne.Pipeline.Prompts.GetMode
  alias Mnemosyne.Pipeline.Prompts.GetPlan
  alias Mnemosyne.Pipeline.Prompts.GetRefinedQuery

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
  @spec retrieve(String.t(), keyword()) ::
          {:ok, Result.t(), RecallTrace.t()} | {:error, Mnemosyne.Errors.error()}
  def retrieve(query, opts) do
    Mnemosyne.Telemetry.span(
      [:retrieval, :retrieve],
      %{repo_id: Keyword.get(opts, :repo_id), session_id: Keyword.get(opts, :session_id)},
      fn ->
        llm = Keyword.fetch!(opts, :llm)
        embedding = Keyword.fetch!(opts, :embedding)
        backend = Keyword.fetch!(opts, :backend)
        value_fns = Keyword.fetch!(opts, :value_function)
        llm_opts = Keyword.get(opts, :llm_opts, [])
        config = Keyword.get(opts, :config)
        max_hops = Keyword.get(opts, :max_hops, @default_max_hops)
        verbosity = if config, do: config.trace_verbosity, else: :summary
        start_time = System.monotonic_time(:microsecond)

        with {:ok, mode} <- classify_mode(query, llm, llm_opts, config),
             {:ok, tags} <- generate_plan(query, mode, llm, llm_opts, config),
             {:ok, %Embedding.Response{vectors: tag_vectors}} <-
               embedding.embed_batch(tags, Config.embedding_opts(config)),
             {:ok, %Embedding.Response{vectors: [query_vector]}} <-
               embedding.embed(query, Config.embedding_opts(config)) do
          Logger.debug("retrieval mode classified as #{mode}")

          target_types = types_for_mode(mode)

          candidates = hop_0(backend, query_vector, tag_vectors, target_types, value_fns)

          best_relevance = best_candidate_relevance(candidates, query_vector)
          refinement_threshold = refinement_threshold(config)

          refined_vectors =
            maybe_refine_query(
              query,
              candidates,
              best_relevance,
              refinement_threshold,
              llm,
              embedding,
              llm_opts,
              config
            )

          candidates =
            candidates
            |> multi_hop(backend, query_vector, value_fns, max_hops, mode, refined_vectors)
            |> maybe_expand_provenance(backend, mode)
            |> partition_by_type()

          total_candidates =
            candidates |> Map.values() |> List.flatten() |> length()

          duration_us = System.monotonic_time(:microsecond) - start_time

          trace = %RecallTrace{
            verbosity: verbosity,
            mode: mode,
            tags: tags,
            candidate_count: total_candidates,
            hops: max_hops,
            result_count: total_candidates,
            duration_us: duration_us
          }

          result = %Result{mode: mode, tags: tags, candidates: candidates}
          {{:ok, result, trace}, %{candidates_found: total_candidates}}
        else
          error -> {error, %{}}
        end
      end
    )
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

  defp best_candidate_relevance([], _query_vector), do: 0.0

  defp best_candidate_relevance(candidates, query_vector) do
    candidates
    |> Enum.map(fn {node, _score} ->
      case NodeProtocol.embedding(node) do
        nil -> 0.0
        emb -> Similarity.cosine_similarity(query_vector, emb)
      end
    end)
    |> Enum.max(fn -> 0.0 end)
  end

  defp refinement_threshold(nil), do: 0.6
  defp refinement_threshold(config), do: config.refinement_threshold

  defp inject_refined_candidates(
         new_nodes,
         nil,
         _backend,
         _query_vector,
         _value_fns,
         _mode,
         _seen_ids
       ),
       do: new_nodes

  defp inject_refined_candidates(
         new_nodes,
         refined_vectors,
         backend,
         query_vector,
         value_fns,
         mode,
         seen_ids
       ) do
    {mod, bs} = backend
    target_types = types_for_mode(mode)

    case mod.find_candidates(target_types, query_vector, refined_vectors, value_fns, [], bs) do
      {:ok, refined_candidates, _bs} ->
        refined_new =
          Enum.reject(refined_candidates, fn {node, _} ->
            MapSet.member?(seen_ids, NodeProtocol.id(node))
          end)

        new_nodes ++ Enum.map(refined_new, fn {node, _} -> node end)

      _ ->
        new_nodes
    end
  end

  defp maybe_refine_query(
         _query,
         _candidates,
         best_relevance,
         threshold,
         _llm,
         _embedding,
         _llm_opts,
         _config
       )
       when best_relevance >= threshold,
       do: nil

  defp maybe_refine_query(
         query,
         candidates,
         _best_relevance,
         _threshold,
         llm,
         embedding,
         llm_opts,
         config
       ) do
    summaries = summarize_candidates(candidates)
    mode = infer_mode_from_candidates(candidates)

    messages =
      GetRefinedQuery.build_messages(%{
        original_query: query,
        mode: mode,
        retrieved_so_far: summaries
      })

    with {:ok, %{content: content}} <-
           llm.chat_structured(
             messages,
             GetRefinedQuery.schema(),
             Config.llm_opts(config, :get_refined_query, llm_opts)
           ),
         {:ok, [_ | _] = tags} <- GetRefinedQuery.parse_response(content),
         {:ok, %Embedding.Response{vectors: vectors}} <-
           embedding.embed_batch(tags, Config.embedding_opts(config)) do
      vectors
    else
      _ -> nil
    end
  end

  defp summarize_candidates(candidates) do
    Enum.map(candidates, fn {node, _score} ->
      type = NodeProtocol.node_type(node)
      content = node_content_summary(node)
      %{type: type, content: content}
    end)
  end

  defp node_content_summary(%{proposition: p}), do: p
  defp node_content_summary(%{instruction: i}), do: i
  defp node_content_summary(%{observation: o, action: a}), do: "#{o} -> #{a}"
  defp node_content_summary(%{description: d}), do: d
  defp node_content_summary(_), do: ""

  defp infer_mode_from_candidates(candidates) do
    types = Enum.map(candidates, fn {node, _} -> NodeProtocol.node_type(node) end) |> Enum.uniq()

    cond do
      :semantic in types and :procedural in types -> :mixed
      :procedural in types -> :procedural
      :episodic in types -> :episodic
      true -> :semantic
    end
  end

  defp multi_hop(candidates, _backend, _query_vector, _value_fns, 0, _mode, _refined_vectors),
    do: candidates

  defp multi_hop(
         candidates,
         backend,
         query_vector,
         value_fns,
         hops_remaining,
         mode,
         refined_vectors
       ) do
    seen_ids = MapSet.new(candidates, fn {node, _} -> NodeProtocol.id(node) end)
    routing_types = routing_types_for_mode(mode)
    new_nodes = expand_through_routing_nodes(candidates, backend, seen_ids, routing_types)

    new_nodes =
      inject_refined_candidates(
        new_nodes,
        refined_vectors,
        backend,
        query_vector,
        value_fns,
        mode,
        seen_ids
      )

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

    multi_hop(merged, backend, query_vector, value_fns, hops_remaining - 1, mode, nil)
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
