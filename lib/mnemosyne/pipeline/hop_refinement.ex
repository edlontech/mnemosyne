defmodule Mnemosyne.Pipeline.HopRefinement do
  @moduledoc """
  Per-hop query refinement for the retrieval pipeline.

  Tracks retrieval quality across hops and triggers LLM-based tag
  refinement when score improvement plateaus. Budget-limited to
  avoid excessive LLM calls.
  """

  require Logger

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.Graph.Node, as: NodeProtocol
  alias Mnemosyne.LLM
  alias Mnemosyne.Pipeline.Prompts.GetRefinedQuery
  alias Mnemosyne.Pipeline.Retrieval.TaggedCandidate

  defmodule State do
    @moduledoc """
    Tracks refinement state across hops during retrieval.
    """

    defstruct budget_remaining: 0,
              previous_best_score: 0.6,
              plateau_delta: 0.05,
              refinement_count: 0,
              refinements: []

    @type t :: %__MODULE__{
            budget_remaining: non_neg_integer(),
            previous_best_score: float(),
            plateau_delta: float(),
            refinement_count: non_neg_integer(),
            refinements: [map()]
          }
  end

  @doc """
  Initializes refinement state from config and the pipeline's max hop count.
  Budget is capped at `max_hops` to avoid exceeding the traversal depth.
  """
  @spec init(Config.t(), non_neg_integer()) :: State.t()
  def init(%Config{} = config, max_hops) do
    %State{
      budget_remaining: min(config.refinement_budget, max_hops),
      previous_best_score: config.refinement_threshold,
      plateau_delta: config.plateau_delta,
      refinement_count: 0,
      refinements: []
    }
  end

  @doc """
  Conditionally refines retrieval tags based on score plateau detection.

  Returns `{:refined, tags, vectors, new_state}` when refinement is triggered
  and succeeds, or `{:skip, new_state}` otherwise.

  The `ctx` map must contain `:llm`, `:embedding`, `:config`, and `:llm_opts`.
  """
  @spec maybe_refine(State.t(), String.t(), [TaggedCandidate.t()], non_neg_integer(), map()) ::
          {:refined, [String.t()], [[float()]], State.t()} | {:skip, State.t()}
  def maybe_refine(%State{budget_remaining: 0} = state, _query, _candidates, _hop, _ctx) do
    {:skip, state}
  end

  def maybe_refine(%State{} = state, query, candidates, hop, ctx) do
    metadata = %{hop: hop, budget_remaining: state.budget_remaining}

    Mnemosyne.Telemetry.span([:retrieval, :hop_refinement], metadata, fn ->
      best_new_score = best_score_for_hop(candidates, hop, state.previous_best_score)
      delta = best_new_score - state.previous_best_score

      if delta < state.plateau_delta do
        result = do_refine(state, query, candidates, hop, best_new_score, ctx)
        {result, %{triggered: true, plateau_delta: delta}}
      else
        result = {:skip, %{state | previous_best_score: best_new_score}}
        {result, %{triggered: false, plateau_delta: delta}}
      end
    end)
  end

  defp do_refine(state, query, candidates, hop, best_new_score, ctx) do
    {duration_us, result} = :timer.tc(fn -> run_refinement(query, candidates, hop, ctx) end)

    case result do
      {:ok, tags, vectors} ->
        trace_entry = %{
          hop: hop,
          tags: tags,
          previous_best_score: state.previous_best_score,
          new_best_score: best_new_score,
          duration_us: duration_us
        }

        new_state = %{
          state
          | budget_remaining: state.budget_remaining - 1,
            previous_best_score: best_new_score,
            refinement_count: state.refinement_count + 1,
            refinements: [trace_entry | state.refinements]
        }

        {:refined, tags, vectors, new_state}

      :skip ->
        {:skip, %{state | previous_best_score: best_new_score}}
    end
  end

  defp run_refinement(query, candidates, hop, ctx) do
    summaries = summarize_with_hops(candidates)
    mode = infer_mode(candidates)

    messages =
      GetRefinedQuery.build_messages(%{
        original_query: query,
        mode: mode,
        retrieved_so_far: summaries,
        overlay: Config.resolve_overlay(ctx.config, :get_refined_query)
      })

    llm_opts = Config.llm_opts(ctx.config, :get_refined_query, ctx.llm_opts)

    with {:ok, %LLM.Response{content: content}} <-
           ctx.llm.chat_structured(messages, GetRefinedQuery.schema(), llm_opts),
         {:ok, [_ | _] = tags} <- GetRefinedQuery.parse_response(content),
         {:ok, %Embedding.Response{vectors: vectors}} <-
           ctx.embedding.embed_batch(tags, Config.embedding_opts(ctx.config)) do
      {:ok, tags, vectors}
    else
      error ->
        Logger.debug("hop refinement failed at hop #{hop}: #{inspect(error)}")
        :skip
    end
  end

  defp best_score_for_hop(candidates, hop, fallback) do
    candidates
    |> Enum.filter(fn %TaggedCandidate{hop: h} -> h == hop end)
    |> Enum.map(fn %TaggedCandidate{score: score} -> score end)
    |> Enum.max(fn -> fallback end)
  end

  defp summarize_with_hops(candidates) do
    candidates
    |> Enum.sort_by(fn %TaggedCandidate{hop: h} -> hop_sort_key(h) end)
    |> Enum.take(20)
    |> Enum.map(fn %TaggedCandidate{node: node, hop: hop} ->
      type = NodeProtocol.node_type(node)
      content = node_content(node) |> String.slice(0, 200)
      hop_label = hop_label(hop)
      %{type: type, content: "#{hop_label} #{content}"}
    end)
  end

  defp hop_sort_key(nil), do: 999
  defp hop_sort_key(h), do: h

  defp hop_label(nil), do: "[phase]"
  defp hop_label(0), do: "[Hop 0]"
  defp hop_label(n), do: "[Hop #{n} - new]"

  defp node_content(%{proposition: p}), do: p
  defp node_content(%{instruction: i}), do: i
  defp node_content(%{observation: o, action: a}), do: "#{o} -> #{a}"
  defp node_content(%{description: d}), do: d
  defp node_content(_), do: ""

  defp infer_mode(candidates) do
    types =
      candidates
      |> Enum.map(fn %TaggedCandidate{node: node} -> NodeProtocol.node_type(node) end)
      |> Enum.uniq()

    cond do
      :semantic in types and :procedural in types -> :mixed
      :procedural in types -> :procedural
      :episodic in types -> :episodic
      true -> :semantic
    end
  end
end
