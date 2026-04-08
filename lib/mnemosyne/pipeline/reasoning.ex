defmodule Mnemosyne.Pipeline.Reasoning do
  @moduledoc """
  Parallel reasoning module that synthesizes retrieved memory candidates
  into typed summaries.

  Partitions candidates by node type, runs the appropriate reasoning
  prompt for each non-empty partition in parallel, and returns a
  `ReasonedMemory` struct.
  """

  require Logger

  alias Mnemosyne.Config
  alias Mnemosyne.LLM
  alias Mnemosyne.Pipeline.Prompts.ReasonEpisodic
  alias Mnemosyne.Pipeline.Prompts.ReasonProcedural
  alias Mnemosyne.Pipeline.Prompts.ReasonSemantic
  alias Mnemosyne.Pipeline.Retrieval
  alias Mnemosyne.Pipeline.Retrieval.TaggedCandidate

  use TypedStruct

  typedstruct module: ReasonedMemory do
    @moduledoc """
    Result of reasoning over retrieved memory candidates.
    Each field is nil when no candidates of that type were found.
    """

    field :episodic, String.t() | nil, default: nil
    field :semantic, String.t() | nil, default: nil
    field :procedural, String.t() | nil, default: nil
  end

  @doc """
  Reasons over a retrieval result, producing typed summaries.

  Options:
    - `:llm` (required) - LLM module implementing the LLM behaviour
    - `:query` (required) - The original query string
    - `:llm_opts` - Additional LLM options (default: [])
    - `:config` - Config struct for per-step model overrides
  """
  @spec reason(Retrieval.Result.t(), keyword()) ::
          {:ok, ReasonedMemory.t()} | {:error, Mnemosyne.Errors.error()}
  def reason(%Retrieval.Result{candidates: candidates}, opts) do
    Mnemosyne.Telemetry.span(
      [:reasoning, :reason],
      %{repo_id: Keyword.get(opts, :repo_id), session_id: Keyword.get(opts, :session_id)},
      fn ->
        do_reason(candidates, opts)
      end
    )
  end

  defp do_reason(candidates, opts) do
    llm = Keyword.fetch!(opts, :llm)
    query = Keyword.fetch!(opts, :query)
    llm_opts = Keyword.get(opts, :llm_opts, [])
    config = Keyword.get(opts, :config)

    candidate_types =
      candidates
      |> Enum.reject(fn {_type, nodes} -> nodes == [] end)
      |> Enum.map(fn {type, _} -> type end)

    tasks =
      Enum.reject(
        [
          maybe_reason(:episodic, candidates, query, llm, llm_opts, config),
          maybe_reason(:semantic, candidates, query, llm, llm_opts, config),
          maybe_reason(:procedural, candidates, query, llm, llm_opts, config)
        ],
        &is_nil/1
      )

    results = await_with_timeout(tasks, "reasoning")

    case collect_results(results) do
      {:ok, summaries} ->
        memory = build_memory(summaries)
        {{:ok, memory}, %{candidate_types: candidate_types}}

      {:error, _} = err ->
        {err, %{}}
    end
  end

  defp build_memory(summaries) do
    Enum.reduce(summaries, %ReasonedMemory{}, fn {type, summary}, acc ->
      Map.put(acc, type, summary)
    end)
  end

  defp await_with_timeout(tasks, label) do
    Task.await_many(tasks, :timer.seconds(60))
  rescue
    e ->
      Logger.warning("#{label} tasks timed out after 60s")
      reraise e, __STACKTRACE__
  end

  defp maybe_reason(type, candidates, query, llm, llm_opts, config) do
    nodes = extract_nodes(candidates, type, config)

    if nodes == [] do
      nil
    else
      Task.async(fn ->
        run_reasoning(type, query, nodes, llm, llm_opts, config)
      end)
    end
  end

  defp extract_nodes(candidates, type, config) do
    top_k = resolve_top_k(type, config)

    candidates
    |> Map.get(type, [])
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(top_k)
    |> Enum.map(fn %TaggedCandidate{node: node} -> node end)
  end

  defp resolve_top_k(type, nil), do: default_top_k(type)

  defp resolve_top_k(type, %Config{} = config) do
    Config.resolve_value_function(config, type).top_k
  end

  defp default_top_k(:episodic), do: 30
  defp default_top_k(:semantic), do: 20
  defp default_top_k(:procedural), do: 10

  defp run_reasoning(:episodic, query, nodes, llm, llm_opts, config) do
    messages = ReasonEpisodic.build_messages(%{query: query, nodes: nodes})

    with {:ok, %LLM.Response{content: content}} <-
           llm.chat_structured(
             messages,
             ReasonEpisodic.schema(),
             Config.llm_opts(config, :reason_episodic, llm_opts)
           ),
         {:ok, summary} <- ReasonEpisodic.parse_response(content) do
      {:ok, {:episodic, summary}}
    end
  end

  defp run_reasoning(:semantic, query, nodes, llm, llm_opts, config) do
    messages = ReasonSemantic.build_messages(%{query: query, nodes: nodes})

    with {:ok, %LLM.Response{content: content}} <-
           llm.chat_structured(
             messages,
             ReasonSemantic.schema(),
             Config.llm_opts(config, :reason_semantic, llm_opts)
           ),
         {:ok, summary} <- ReasonSemantic.parse_response(content) do
      {:ok, {:semantic, summary}}
    end
  end

  defp run_reasoning(:procedural, query, nodes, llm, llm_opts, config) do
    messages = ReasonProcedural.build_messages(%{query: query, nodes: nodes})

    with {:ok, %LLM.Response{content: content}} <-
           llm.chat_structured(
             messages,
             ReasonProcedural.schema(),
             Config.llm_opts(config, :reason_procedural, llm_opts)
           ),
         {:ok, summary} <- ReasonProcedural.parse_response(content) do
      {:ok, {:procedural, summary}}
    end
  end

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, pair}, {:ok, acc} -> {:cont, {:ok, [pair | acc]}}
      {:error, _} = err, _acc -> {:halt, err}
    end)
  end
end
