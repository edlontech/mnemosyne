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
  alias Mnemosyne.NodeMetadata
  alias Mnemosyne.Pipeline.Prompts.MergeIntent, as: MergePrompt

  @doc """
  Merges intent nodes in the changeset, deduplicating against graph and batch.

  ## Options

  - `:backend` - `{module, state}` tuple for the graph backend
  - `:llm` - LLM adapter module
  - `:embedding` - embedding adapter module
  - `:config` - `%Config{}` with threshold settings
  - `:value_function` - value function config map (`:module` + `:params`) for candidate scoring
  """
  @spec merge(Changeset.t(), keyword()) :: {:ok, Changeset.t()} | {:error, term()}
  def merge(%Changeset{} = changeset, opts) do
    {intents, other_nodes} = Enum.split_with(changeset.additions, &match?(%Intent{}, &1))

    if intents == [] do
      {:ok, changeset}
    else
      repo_id = Keyword.get(opts, :repo_id)

      Mnemosyne.Telemetry.span(
        [:intent_merger, :merge],
        %{repo_id: repo_id, intent_count: length(intents)},
        fn ->
          {backend_mod, backend_state} = Keyword.fetch!(opts, :backend)
          llm = Keyword.fetch!(opts, :llm)
          embedding = Keyword.fetch!(opts, :embedding)
          config = Keyword.fetch!(opts, :config)

          value_function =
            Keyword.get(opts, :value_function, %{
              module: Mnemosyne.ValueFunction.Default,
              params: %{}
            })

          {merged_intents, link_rewrites, updated_metadata} =
            process_intents(
              intents,
              backend_mod,
              backend_state,
              llm,
              embedding,
              config,
              value_function,
              changeset.metadata
            )

          rewritten_links = rewrite_links(changeset.links, link_rewrites)
          merged_additions = other_nodes ++ merged_intents
          rewrites_count = map_size(link_rewrites)

          result =
            {:ok,
             %Changeset{
               changeset
               | additions: merged_additions,
                 links: rewritten_links,
                 metadata: updated_metadata
             }}

          {result, %{merged: length(merged_intents), rewrites: rewrites_count}}
        end
      )
    end
  end

  defp process_intents(
         intents,
         backend_mod,
         backend_state,
         llm,
         embedding,
         config,
         value_function,
         metadata
       ) do
    {final_intents, rewrites, _seen, updated_metadata} =
      Enum.reduce(intents, {[], %{}, %{}, metadata}, fn intent,
                                                        {acc_intents, acc_rewrites, seen,
                                                         acc_meta} ->
        graph_match = find_graph_match(intent, backend_mod, backend_state, value_function)
        batch_match = find_batch_match(intent, seen)
        best = pick_best_match(graph_match, batch_match)

        apply_strategy(
          classify_match(best, config),
          intent,
          {acc_intents, acc_rewrites, seen, acc_meta},
          llm,
          embedding,
          config
        )
      end)

    {Enum.reverse(final_intents), rewrites, updated_metadata}
  end

  defp apply_strategy(
         :no_match,
         intent,
         {acc_intents, acc_rewrites, seen, meta},
         _llm,
         _emb,
         _cfg
       ) do
    {[intent | acc_intents], acc_rewrites, Map.put(seen, intent.id, intent), meta}
  end

  defp apply_strategy(
         {:identity, existing},
         intent,
         {acc_intents, acc_rewrites, seen, meta},
         _,
         _,
         _
       ) do
    updated_meta = propagate_reward(meta, intent.id, existing.id)
    {acc_intents, Map.put(acc_rewrites, intent.id, existing.id), seen, updated_meta}
  end

  defp apply_strategy(
         {:merge, existing},
         intent,
         {acc_intents, acc_rewrites, seen, meta},
         llm,
         emb,
         cfg
       ) do
    case llm_merge(intent, existing, llm, emb, cfg) do
      {:ok, merged} ->
        updated_meta = propagate_reward(meta, intent.id, merged.id)
        seen = Map.put(seen, merged.id, merged)
        rewrites = Map.put(acc_rewrites, intent.id, merged.id)
        {replace_or_add(acc_intents, merged), rewrites, seen, updated_meta}

      :error ->
        updated_meta = propagate_reward(meta, intent.id, existing.id)
        {acc_intents, Map.put(acc_rewrites, intent.id, existing.id), seen, updated_meta}
    end
  end

  defp propagate_reward(metadata, source_id, target_id) do
    case Map.get(metadata, source_id) do
      %NodeMetadata{cumulative_reward: reward, reward_count: rc} when rc > 0 ->
        target_meta = Map.get(metadata, target_id, NodeMetadata.new())
        updated_target = NodeMetadata.update_reward(target_meta, reward)

        metadata
        |> Map.delete(source_id)
        |> Map.put(target_id, updated_target)

      _ ->
        Map.delete(metadata, source_id)
    end
  end

  defp find_graph_match(intent, backend_mod, backend_state, value_function) do
    case backend_mod.find_candidates(
           [:intent],
           intent.embedding,
           [],
           value_function,
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
    Enum.map(links, fn {from, to, type} ->
      {Map.get(rewrites, from, from), Map.get(rewrites, to, to), type}
    end)
  end
end
