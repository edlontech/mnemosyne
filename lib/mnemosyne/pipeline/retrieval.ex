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
  alias Mnemosyne.Graph.Node.Helpers, as: NodeHelpers
  alias Mnemosyne.Graph.Similarity
  alias Mnemosyne.Notifier.Trace.Recall, as: RecallTrace
  alias Mnemosyne.Pipeline.HopRefinement
  alias Mnemosyne.Pipeline.Prompts.GetMode
  alias Mnemosyne.Pipeline.Prompts.GetPlan
  alias Mnemosyne.Pipeline.Retrieval.TaggedCandidate

  defmodule Result do
    @moduledoc """
    Result of a retrieval operation containing the classified mode,
    generated tags, and scored candidate nodes partitioned by type.
    """

    alias Mnemosyne.Pipeline.Retrieval.TaggedCandidate

    defstruct [:mode, :tags, candidates: %{}, phases: %{}]

    @type t :: %__MODULE__{
            mode: atom(),
            tags: [String.t()],
            candidates: %{atom() => [TaggedCandidate.t()]},
            phases: map()
          }
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

    refinement_state = init_refinement(ctx.config, ctx.max_hops)

    refine_ctx = %{
      llm: ctx.llm,
      embedding: ctx.embedding,
      config: ctx.config,
      llm_opts: ctx.llm_opts,
      query: ctx.query
    }

    hop_ctx = %{
      backend: ctx.backend,
      query_vector: ctx.query_vector,
      value_fns: ctx.value_fns,
      mode: ctx.mode,
      refine_ctx: refine_ctx
    }

    {multihop_us, {candidates, refinement_state}} =
      :timer.tc(fn ->
        multi_hop(candidates, hop_ctx, ctx.max_hops, refinement_state, 1)
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

    refinement_us =
      refinement_state.refinements
      |> Enum.map(& &1.duration_us)
      |> Enum.sum()

    phases = %{
      timings: %{
        hop_0: hop0_us,
        refinement: refinement_us,
        multi_hop: max(0, multihop_us - refinement_us),
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
      phase_timings: phases.timings,
      refinements: refinement_state.refinements
    }

    result = %Result{mode: ctx.mode, tags: ctx.tags, candidates: candidates, phases: phases}
    {{:ok, result, trace}, %{candidates_found: total_candidates}}
  end

  defp classify_mode(query, llm, llm_opts, config) do
    messages =
      GetMode.build_messages(%{query: query, overlay: Config.resolve_overlay(config, :get_mode)})

    with {:ok, %{content: content}} <-
           llm.chat(messages, Config.llm_opts(config, :get_mode, llm_opts)) do
      GetMode.parse_response(content)
    end
  end

  defp generate_plan(query, mode, llm, llm_opts, config) do
    messages =
      GetPlan.build_messages(%{
        query: query,
        mode: mode,
        overlay: Config.resolve_overlay(config, :get_plan)
      })

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

  defp init_refinement(nil, _max_hops) do
    %HopRefinement.State{}
  end

  defp init_refinement(%Config{} = config, max_hops) do
    HopRefinement.init(config, max_hops)
  end

  defp inject_refined_candidates(_backend, _qv, _vf, _mode, _seen, nil, _hop), do: []

  defp inject_refined_candidates(
         backend,
         query_vector,
         value_fns,
         mode,
         seen_ids,
         refined_vectors,
         hop
       ) do
    {mod, bs} = backend
    target_types = types_for_mode(mode)

    case mod.find_candidates(target_types, query_vector, refined_vectors, value_fns, [], bs) do
      {:ok, refined_candidates, _bs} ->
        refined_candidates
        |> Enum.reject(fn {node, _} -> MapSet.member?(seen_ids, NodeProtocol.id(node)) end)
        |> Enum.map(fn {node, score} -> TaggedCandidate.from_refinement(node, score, hop) end)

      _ ->
        []
    end
  end

  defp multi_hop(candidates, _hop_ctx, 0, refinement_state, _current_hop) do
    {candidates, refinement_state}
  end

  defp multi_hop(candidates, hop_ctx, hops_remaining, refinement_state, current_hop) do
    %{
      backend: backend,
      query_vector: query_vector,
      value_fns: value_fns,
      mode: mode,
      refine_ctx: refine_ctx
    } = hop_ctx

    seen_ids =
      MapSet.new(candidates, fn %TaggedCandidate{node: node} -> NodeProtocol.id(node) end)

    routing_types = routing_types_for_mode(mode)

    expanded_nodes =
      expand_through_routing_nodes(
        candidates,
        backend,
        seen_ids,
        routing_types,
        query_vector,
        value_fns
      )

    vf_module = Map.get(value_fns, :module, Mnemosyne.ValueFunction.Default)

    expansion_scored =
      expanded_nodes
      |> Enum.map(fn node ->
        emb = NodeProtocol.embedding(node)
        relevance = if emb, do: Similarity.cosine_similarity(query_vector, emb), else: 0.0
        type = NodeProtocol.node_type(node)
        params = get_in(value_fns, [:params, type]) || %{}
        score = vf_module.score(relevance, node, nil, params)
        TaggedCandidate.from_multi_hop(node, score, current_hop)
      end)
      |> Enum.filter(fn %TaggedCandidate{node: node, score: score} ->
        type = NodeProtocol.node_type(node)
        threshold = get_in(value_fns, [:params, type, :threshold]) || 0.0
        score >= threshold
      end)

    merged =
      (candidates ++ expansion_scored)
      |> Enum.uniq_by(fn %TaggedCandidate{node: node} -> NodeProtocol.id(node) end)
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(@max_candidates_per_hop)

    {refined_vectors, refinement_state} =
      case HopRefinement.maybe_refine(
             refinement_state,
             refine_ctx.query,
             merged,
             current_hop,
             refine_ctx
           ) do
        {:refined, _tags, vectors, new_state} -> {vectors, new_state}
        {:skip, new_state} -> {nil, new_state}
      end

    refined_tagged =
      inject_refined_candidates(
        backend,
        query_vector,
        value_fns,
        mode,
        seen_ids,
        refined_vectors,
        current_hop
      )

    merged =
      if refined_tagged != [] do
        (merged ++ refined_tagged)
        |> Enum.uniq_by(fn %TaggedCandidate{node: node} -> NodeProtocol.id(node) end)
        |> Enum.sort_by(& &1.score, :desc)
        |> Enum.take(@max_candidates_per_hop)
      else
        merged
      end

    multi_hop(merged, hop_ctx, hops_remaining - 1, refinement_state, current_hop + 1)
  end

  @doc false
  def expand_through_routing_nodes(
        candidates,
        backend,
        seen_ids,
        routing_types,
        query_vector,
        value_fns
      ) do
    {mod, bs} = backend
    vf_module = Map.get(value_fns, :module, Mnemosyne.ValueFunction.Default)

    candidate_link_ids =
      candidates
      |> Enum.flat_map(fn %TaggedCandidate{node: node} ->
        node |> NodeHelpers.all_linked_ids() |> MapSet.to_list()
      end)
      |> Enum.uniq()

    {:ok, linked_nodes, _bs} = mod.get_linked_nodes(candidate_link_ids, nil, bs)

    routing_nodes =
      Enum.filter(linked_nodes, fn node ->
        NodeProtocol.node_type(node) in routing_types and
          routing_node_above_threshold?(node, query_vector, value_fns, vf_module)
      end)

    sibling_ids =
      routing_nodes
      |> Enum.flat_map(fn node -> node |> NodeHelpers.all_linked_ids() |> MapSet.to_list() end)
      |> Enum.reject(&MapSet.member?(seen_ids, &1))
      |> Enum.uniq()

    {:ok, siblings, _bs} = mod.get_linked_nodes(sibling_ids, nil, bs)

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
        NodeProtocol.links(node, :provenance) |> MapSet.to_list()
      end)
      |> Enum.reject(&MapSet.member?(candidate_ids, &1))
      |> Enum.uniq()

    {:ok, linked_nodes, _bs} = mod.get_linked_nodes(episodic_link_ids, nil, bs)

    source_nodes =
      linked_nodes
      |> Enum.filter(&(NodeProtocol.node_type(&1) == :source))
      |> Enum.map(fn source ->
        parent_score =
          candidates
          |> Enum.filter(fn %TaggedCandidate{node: node} ->
            NodeProtocol.node_type(node) == :episodic and
              MapSet.member?(NodeProtocol.links(node, :provenance), NodeProtocol.id(source))
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

  defp routing_node_above_threshold?(node, query_vector, value_fns, vf_module) do
    emb = NodeProtocol.embedding(node)
    type = NodeProtocol.node_type(node)
    params = get_in(value_fns, [:params, type]) || %{}
    threshold = Map.get(params, :threshold, 0.0)
    relevance = if emb, do: Similarity.cosine_similarity(query_vector, emb), else: 0.0
    score = vf_module.score(relevance, node, nil, params)
    score >= threshold
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
