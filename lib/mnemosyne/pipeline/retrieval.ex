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
  alias Mnemosyne.Pipeline.Retrieval.TaggedCandidate

  use TypedStruct

  typedstruct module: Result do
    @moduledoc """
    Result of a retrieval operation containing the classified mode,
    generated tags, and scored candidate nodes partitioned by type.
    """

    field :mode, atom()
    field :tags, [String.t()]
    field :candidates, %{atom() => [TaggedCandidate.t()]}, default: %{}
    field :phases, map(), default: %{}
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
          execute_pipeline(%{
            query: query,
            mode: mode,
            tags: tags,
            query_vector: query_vector,
            tag_vectors: tag_vectors,
            backend: backend,
            value_fns: value_fns,
            llm: llm,
            embedding: embedding,
            llm_opts: llm_opts,
            config: config,
            max_hops: max_hops,
            verbosity: verbosity,
            start_time: start_time
          })
        else
          error -> {error, %{}}
        end
      end
    )
  end

  defp execute_pipeline(ctx) do
    Logger.debug("retrieval mode classified as #{ctx.mode}")

    target_types = types_for_mode(ctx.mode)

    {hop0_us, candidates} =
      :timer.tc(fn ->
        hop_0(ctx.backend, ctx.query_vector, ctx.tag_vectors, target_types, ctx.value_fns)
      end)

    hop0_count = length(candidates)
    best_relevance = best_candidate_relevance(candidates, ctx.query_vector)
    threshold = refinement_threshold(ctx.config)

    {refine_us, refined_vectors} =
      :timer.tc(fn ->
        maybe_refine_query(
          ctx.query,
          candidates,
          best_relevance,
          threshold,
          ctx.llm,
          ctx.embedding,
          ctx.llm_opts,
          ctx.config
        )
      end)

    {multihop_us, candidates} =
      :timer.tc(fn ->
        multi_hop(
          candidates,
          ctx.backend,
          ctx.query_vector,
          ctx.value_fns,
          ctx.max_hops,
          ctx.mode,
          refined_vectors,
          1
        )
      end)

    post_multihop_count = length(candidates)
    multihop_rejected = hop0_count - min(hop0_count, post_multihop_count)

    {prov_us, candidates} =
      :timer.tc(fn -> maybe_expand_provenance(candidates, ctx.backend, ctx.mode) end)

    candidates = partition_by_type(candidates)
    total_candidates = candidates |> Map.values() |> List.flatten() |> length()
    duration_us = System.monotonic_time(:microsecond) - ctx.start_time
    scores = build_scores_map(candidates)

    rejected =
      if multihop_rejected > 0,
        do: %{multi_hop: multihop_rejected},
        else: %{}

    phases = %{
      timings: %{
        hop_0: hop0_us,
        refinement: refine_us,
        multi_hop: multihop_us,
        provenance: prov_us
      },
      candidates_per_hop: %{0 => hop0_count, 1 => post_multihop_count},
      rejected: rejected,
      scores: scores
    }

    trace = %RecallTrace{
      verbosity: ctx.verbosity,
      mode: ctx.mode,
      tags: ctx.tags,
      candidate_count: total_candidates,
      hops: ctx.max_hops,
      result_count: total_candidates,
      duration_us: duration_us,
      candidates_per_hop: phases.candidates_per_hop,
      scores: phases.scores,
      rejected: phases.rejected,
      phase_timings: phases.timings
    }

    result = %Result{mode: ctx.mode, tags: ctx.tags, candidates: candidates, phases: phases}
    {{:ok, result, trace}, %{candidates_found: total_candidates}}
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

    Enum.map(candidates, fn {node, score} -> TaggedCandidate.from_hop_0(node, score) end)
  end

  defp best_candidate_relevance([], _query_vector), do: 0.0

  defp best_candidate_relevance(candidates, query_vector) do
    candidates
    |> Enum.map(fn %TaggedCandidate{node: node} ->
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
         _backend,
         _query_vector,
         _value_fns,
         _mode,
         _seen_ids,
         nil
       ),
       do: []

  defp inject_refined_candidates(
         backend,
         query_vector,
         value_fns,
         mode,
         seen_ids,
         refined_vectors
       ) do
    {mod, bs} = backend
    target_types = types_for_mode(mode)

    case mod.find_candidates(target_types, query_vector, refined_vectors, value_fns, [], bs) do
      {:ok, refined_candidates, _bs} ->
        refined_candidates
        |> Enum.reject(fn {node, _} -> MapSet.member?(seen_ids, NodeProtocol.id(node)) end)
        |> Enum.map(fn {node, score} -> TaggedCandidate.from_refinement(node, score) end)

      _ ->
        []
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
    Enum.map(candidates, fn %TaggedCandidate{node: node} ->
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
    types =
      Enum.map(candidates, fn %TaggedCandidate{node: node} -> NodeProtocol.node_type(node) end)
      |> Enum.uniq()

    cond do
      :semantic in types and :procedural in types -> :mixed
      :procedural in types -> :procedural
      :episodic in types -> :episodic
      true -> :semantic
    end
  end

  defp multi_hop(
         candidates,
         _backend,
         _query_vector,
         _value_fns,
         0,
         _mode,
         _refined_vectors,
         _current_hop
       ),
       do: candidates

  defp multi_hop(
         candidates,
         backend,
         query_vector,
         value_fns,
         hops_remaining,
         mode,
         refined_vectors,
         current_hop
       ) do
    seen_ids =
      MapSet.new(candidates, fn %TaggedCandidate{node: node} -> NodeProtocol.id(node) end)

    routing_types = routing_types_for_mode(mode)
    expanded_nodes = expand_through_routing_nodes(candidates, backend, seen_ids, routing_types)

    refined_tagged =
      inject_refined_candidates(backend, query_vector, value_fns, mode, seen_ids, refined_vectors)

    vf_module = Map.get(value_fns, :module, Mnemosyne.ValueFunction.Default)

    expansion_scored =
      Enum.map(expanded_nodes, fn node ->
        emb = NodeProtocol.embedding(node)
        relevance = if emb, do: Similarity.cosine_similarity(query_vector, emb), else: 0.0
        type = NodeProtocol.node_type(node)
        params = get_in(value_fns, [:params, type]) || %{}
        score = vf_module.score(relevance, node, nil, params)
        TaggedCandidate.from_multi_hop(node, score, current_hop)
      end)

    scored = expansion_scored ++ refined_tagged

    merged =
      (candidates ++ scored)
      |> Enum.uniq_by(fn %TaggedCandidate{node: node} -> NodeProtocol.id(node) end)
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(@max_candidates_per_hop)

    multi_hop(
      merged,
      backend,
      query_vector,
      value_fns,
      hops_remaining - 1,
      mode,
      nil,
      current_hop + 1
    )
  end

  @doc false
  def expand_through_routing_nodes(candidates, backend, seen_ids, routing_types) do
    {mod, bs} = backend

    candidate_link_ids =
      candidates
      |> Enum.flat_map(fn %TaggedCandidate{node: node} ->
        NodeProtocol.links(node) |> MapSet.to_list()
      end)
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

    candidate_ids =
      MapSet.new(candidates, fn %TaggedCandidate{node: node} -> NodeProtocol.id(node) end)

    episodic_link_ids =
      candidates
      |> Enum.filter(fn %TaggedCandidate{node: node} ->
        NodeProtocol.node_type(node) == :episodic
      end)
      |> Enum.flat_map(fn %TaggedCandidate{node: node} ->
        NodeProtocol.links(node) |> MapSet.to_list()
      end)
      |> Enum.reject(&MapSet.member?(candidate_ids, &1))
      |> Enum.uniq()

    {:ok, linked_nodes, _bs} = mod.get_linked_nodes(episodic_link_ids, bs)

    source_nodes =
      linked_nodes
      |> Enum.filter(&(NodeProtocol.node_type(&1) == :source))
      |> Enum.map(fn source ->
        parent_score =
          candidates
          |> Enum.filter(fn %TaggedCandidate{node: node} ->
            NodeProtocol.node_type(node) == :episodic and
              MapSet.member?(NodeProtocol.links(node), NodeProtocol.id(source))
          end)
          |> Enum.map(fn %TaggedCandidate{score: score} -> score end)
          |> Enum.max(fn -> 0.0 end)

        TaggedCandidate.from_provenance(source, parent_score * @provenance_decay)
      end)

    candidates ++ source_nodes
  end

  defp maybe_expand_provenance(candidates, _backend, _mode), do: candidates

  defp partition_by_type(candidates) do
    Enum.group_by(
      candidates,
      fn %TaggedCandidate{node: node} -> NodeProtocol.node_type(node) end
    )
  end

  defp build_scores_map(candidates) do
    candidates
    |> Map.values()
    |> List.flatten()
    |> Map.new(fn %TaggedCandidate{node: node, score: score} ->
      {NodeProtocol.id(node), score}
    end)
  end
end
