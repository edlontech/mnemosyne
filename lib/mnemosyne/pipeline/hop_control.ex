defmodule Mnemosyne.Pipeline.HopControl do
  @moduledoc """
  LLM-driven control of the multi-hop retrieval loop.

  At each hop, an LLM controller assesses whether the accumulated
  candidates are sufficient to answer the query. When they are, retrieval
  stops early. When they are not, the controller selects a small focus
  set of candidates whose content drives the next-hop query, and the
  retrieval tags are regenerated conditioned on what has been retrieved
  so far. Tag refinement is capped by the configured refinement budget
  to bound LLM cost.
  """

  require Logger

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.Graph.Node, as: NodeProtocol
  alias Mnemosyne.LLM
  alias Mnemosyne.Pipeline.Prompts.GetRefinedQuery
  alias Mnemosyne.Pipeline.Prompts.MultiHopControl
  alias Mnemosyne.Pipeline.Retrieval.TaggedCandidate

  @max_focus 2
  @max_control_candidates 20

  defmodule State do
    @moduledoc """
    Tracks control decisions and refinement usage across hops during retrieval.
    """

    defstruct budget_remaining: 0,
              refinement_count: 0,
              refinements: [],
              stopped_early_at: nil

    @type t :: %__MODULE__{
            budget_remaining: non_neg_integer(),
            refinement_count: non_neg_integer(),
            refinements: [map()],
            stopped_early_at: non_neg_integer() | nil
          }
  end

  @doc """
  Initializes control state from config and the pipeline's max hop count.
  The refinement budget is capped at `max_hops` to avoid exceeding the
  traversal depth. Without config, refinement is disabled but the
  sufficiency controller still runs.
  """
  @spec init(Config.t() | nil, non_neg_integer()) :: State.t()
  def init(nil, _max_hops), do: %State{}

  def init(%Config{} = config, max_hops) do
    %State{budget_remaining: min(config.refinement_budget, max_hops)}
  end

  @doc """
  Assesses whether retrieval can stop at the current hop.

  Returns `{:stop, state}` when the controller judges the candidates
  sufficient, or `{:continue, focus_candidates, state}` with up to
  #{@max_focus} focus candidates selected to drive the next hop.
  Degrades to `{:continue, [], state}` on any LLM or parse failure so
  retrieval never breaks on controller errors.
  """
  @spec assess(State.t(), String.t(), [TaggedCandidate.t()], non_neg_integer(), map()) ::
          {:stop, State.t()} | {:continue, [TaggedCandidate.t()], State.t()}
  def assess(%State{} = state, _query, [], _hop, _ctx), do: {:continue, [], state}

  def assess(%State{} = state, query, candidates, hop, ctx) do
    metadata = %{hop: hop, candidate_count: length(candidates)}

    Mnemosyne.Telemetry.span([:retrieval, :hop_control], metadata, fn ->
      shown = Enum.take(candidates, @max_control_candidates)

      summaries =
        shown
        |> Enum.with_index()
        |> Enum.map(fn {%TaggedCandidate{node: node}, idx} ->
          %{
            index: idx,
            type: NodeProtocol.node_type(node),
            content: node |> node_content() |> String.slice(0, 200)
          }
        end)

      messages =
        MultiHopControl.build_messages(%{
          query: query,
          candidates: summaries,
          max_focus: @max_focus,
          overlay: Config.resolve_overlay(ctx.config, :multi_hop_control)
        })

      llm_opts = Config.llm_opts(ctx.config, :multi_hop_control, ctx.llm_opts)

      case run_control(ctx.llm, messages, llm_opts) do
        {:ok, %{enough: true}} ->
          {{:stop, %{state | stopped_early_at: hop}}, %{decision: :stop}}

        {:ok, %{enough: false, top_indices: indices}} ->
          focus =
            indices
            |> Enum.uniq()
            |> Enum.filter(&(&1 >= 0 and &1 < length(shown)))
            |> Enum.take(@max_focus)
            |> Enum.map(&Enum.at(shown, &1))

          {{:continue, focus, state}, %{decision: :continue, focus_count: length(focus)}}

        :error ->
          {{:continue, [], state}, %{decision: :continue, focus_count: 0}}
      end
    end)
  end

  @doc """
  Regenerates retrieval tags conditioned on the query and candidates
  retrieved so far. Runs whenever refinement budget remains.

  Returns `{:refined, tags, vectors, new_state}` on success, or
  `{:skip, new_state}` when the budget is exhausted or refinement fails.
  """
  @spec refine(State.t(), String.t(), [TaggedCandidate.t()], non_neg_integer(), map()) ::
          {:refined, [String.t()], [[float()]], State.t()} | {:skip, State.t()}
  def refine(%State{budget_remaining: 0} = state, _query, _candidates, _hop, _ctx) do
    {:skip, state}
  end

  def refine(%State{} = state, query, candidates, hop, ctx) do
    metadata = %{hop: hop, budget_remaining: state.budget_remaining}

    Mnemosyne.Telemetry.span([:retrieval, :hop_refinement], metadata, fn ->
      {duration_us, result} = :timer.tc(fn -> run_refinement(query, candidates, hop, ctx) end)

      case result do
        {:ok, tags, vectors} ->
          trace_entry = %{hop: hop, tags: tags, duration_us: duration_us}

          new_state = %{
            state
            | budget_remaining: state.budget_remaining - 1,
              refinement_count: state.refinement_count + 1,
              refinements: [trace_entry | state.refinements]
          }

          {{:refined, tags, vectors, new_state}, %{triggered: true}}

        :skip ->
          {{:skip, state}, %{triggered: false}}
      end
    end)
  end

  @doc "Extracts the primary text content of a node for prompt display."
  @spec node_content(struct()) :: String.t()
  def node_content(%{proposition: p}) when is_binary(p), do: p
  def node_content(%{instruction: i}) when is_binary(i), do: i
  def node_content(%{observation: o, action: a}), do: "#{o} -> #{a}"
  def node_content(%{description: d}) when is_binary(d), do: d
  def node_content(_), do: ""

  defp run_control(llm, messages, llm_opts) do
    with {:ok, %LLM.Response{content: content}} <-
           llm.chat_structured(messages, MultiHopControl.schema(), llm_opts),
         {:ok, decision} <- MultiHopControl.parse_response(content) do
      {:ok, decision}
    else
      error ->
        Logger.debug("multi-hop control failed, continuing retrieval: #{inspect(error)}")
        :error
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

  defp summarize_with_hops(candidates) do
    candidates
    |> Enum.sort_by(fn %TaggedCandidate{hop: h} -> hop_sort_key(h) end)
    |> Enum.take(20)
    |> Enum.map(fn %TaggedCandidate{node: node, hop: hop} ->
      type = NodeProtocol.node_type(node)
      content = node |> node_content() |> String.slice(0, 200)
      %{type: type, content: "#{hop_label(hop)} #{content}"}
    end)
  end

  defp hop_sort_key(nil), do: 999
  defp hop_sort_key(h), do: h

  defp hop_label(nil), do: "[phase]"
  defp hop_label(0), do: "[Hop 0]"
  defp hop_label(n), do: "[Hop #{n} - new]"

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
