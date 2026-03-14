defmodule Mnemosyne.Pipeline.IntentMerger do
  @moduledoc """
  Deduplicates intent nodes in a changeset against both the existing
  graph and other intents within the same batch.

  Applies three strategies based on cosine similarity thresholds:
  - Below merge threshold: keep the new intent as-is
  - Between merge and identity thresholds: LLM-merge descriptions, re-embed
  - Above identity threshold: drop duplicate, rewrite links to existing intent
  """

  require Logger

  alias Mnemosyne.Config
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Intent
  alias Mnemosyne.Graph.Similarity
  alias Mnemosyne.Pipeline.Prompts.MergeIntent, as: MergePrompt

  @doc """
  Merges intent nodes in the changeset, deduplicating against graph and batch.

  ## Options

  - `:backend` - `{module, state}` tuple for the graph backend
  - `:llm` - LLM adapter module
  - `:embedding` - embedding adapter module
  - `:config` - `%Config{}` with threshold settings
  - `:value_functions` - value function map for candidate scoring
  """
  @spec merge(Changeset.t(), keyword()) :: {:ok, Changeset.t()}
  def merge(%Changeset{} = changeset, opts) do
    {intents, other_nodes} = Enum.split_with(changeset.additions, &match?(%Intent{}, &1))

    if intents == [] do
      {:ok, changeset}
    else
      {backend_mod, backend_state} = Keyword.fetch!(opts, :backend)
      llm = Keyword.fetch!(opts, :llm)
      embedding = Keyword.fetch!(opts, :embedding)
      config = Keyword.fetch!(opts, :config)
      value_functions = Keyword.get(opts, :value_functions, %{})

      {merged_intents, link_rewrites} =
        process_intents(
          intents,
          backend_mod,
          backend_state,
          llm,
          embedding,
          config,
          value_functions
        )

      rewritten_links = rewrite_links(changeset.links, link_rewrites)
      merged_additions = other_nodes ++ merged_intents

      {:ok, %Changeset{changeset | additions: merged_additions, links: rewritten_links}}
    end
  end

  defp process_intents(
         intents,
         backend_mod,
         backend_state,
         llm,
         embedding,
         config,
         value_functions
       ) do
    {final_intents, rewrites, _seen} =
      Enum.reduce(intents, {[], %{}, %{}}, fn intent, {acc_intents, acc_rewrites, seen} ->
        graph_match = find_graph_match(intent, backend_mod, backend_state, value_functions)
        batch_match = find_batch_match(intent, seen)
        best = pick_best_match(graph_match, batch_match)

        apply_strategy(
          classify_match(best, config),
          intent,
          {acc_intents, acc_rewrites, seen},
          llm,
          embedding,
          config
        )
      end)

    {Enum.reverse(final_intents), rewrites}
  end

  defp apply_strategy(:no_match, intent, {acc_intents, acc_rewrites, seen}, _llm, _emb, _cfg) do
    {[intent | acc_intents], acc_rewrites, Map.put(seen, intent.id, intent)}
  end

  defp apply_strategy({:identity, existing}, intent, {acc_intents, acc_rewrites, seen}, _, _, _) do
    {acc_intents, Map.put(acc_rewrites, intent.id, existing.id), seen}
  end

  defp apply_strategy(
         {:merge, existing},
         intent,
         {acc_intents, acc_rewrites, seen},
         llm,
         emb,
         cfg
       ) do
    case llm_merge(intent, existing, llm, emb, cfg) do
      {:ok, merged} ->
        seen = Map.put(seen, merged.id, merged)
        rewrites = Map.put(acc_rewrites, intent.id, merged.id)
        {replace_or_add(acc_intents, merged), rewrites, seen}

      :error ->
        {[intent | acc_intents], acc_rewrites, Map.put(seen, intent.id, intent)}
    end
  end

  defp find_graph_match(intent, backend_mod, backend_state, value_functions) do
    case backend_mod.find_candidates(
           [:intent],
           intent.embedding,
           [],
           value_functions,
           [],
           backend_state
         ) do
      {:ok, [{node, score} | _], _state} -> {node, score}
      _ -> nil
    end
  end

  defp find_batch_match(_intent, seen) when map_size(seen) == 0, do: nil

  defp find_batch_match(intent, seen) do
    seen
    |> Enum.map(fn {_id, existing} ->
      score = Similarity.cosine_similarity(intent.embedding, existing.embedding)
      {existing, score}
    end)
    |> Enum.filter(fn {_node, score} -> is_float(score) end)
    |> case do
      [] -> nil
      candidates -> Enum.max_by(candidates, &elem(&1, 1))
    end
  end

  defp pick_best_match(nil, nil), do: nil
  defp pick_best_match(match, nil), do: match
  defp pick_best_match(nil, match), do: match

  defp pick_best_match({_n1, s1} = m1, {_n2, s2} = m2) do
    if s1 >= s2, do: m1, else: m2
  end

  defp classify_match(nil, _config), do: :no_match

  defp classify_match({node, score}, config) do
    cond do
      score >= config.intent_identity_threshold -> {:identity, node}
      score >= config.intent_merge_threshold -> {:merge, node}
      true -> :no_match
    end
  end

  defp llm_merge(new_intent, %Intent{} = existing, llm, embedding, config) do
    messages =
      MergePrompt.build_messages(%{
        existing_intent: existing.description,
        new_intent: new_intent.description
      })

    llm_opts = Config.llm_opts(config, :merge_intent, [])
    embedding_opts = Config.embedding_opts(config)

    with {:ok, %{content: content}} <-
           llm.chat_structured(messages, MergePrompt.schema(), llm_opts),
         {:ok, merged_desc} <- MergePrompt.parse_response(content),
         {:ok, %{vectors: [new_embedding]}} <-
           embedding.embed_batch([merged_desc], embedding_opts) do
      merged = %Intent{existing | description: merged_desc, embedding: new_embedding}
      {:ok, merged}
    else
      error ->
        Logger.warning("intent merge failed, keeping new intent: #{inspect(error)}")
        :error
    end
  end

  defp replace_or_add(intents, merged) do
    if Enum.any?(intents, &(&1.id == merged.id)) do
      Enum.map(intents, fn
        %Intent{id: id} when id == merged.id -> merged
        other -> other
      end)
    else
      [merged | intents]
    end
  end

  defp rewrite_links(links, rewrites) when map_size(rewrites) == 0, do: links

  defp rewrite_links(links, rewrites) do
    Enum.map(links, fn {from, to} ->
      {Map.get(rewrites, from, from), Map.get(rewrites, to, to)}
    end)
  end
end
