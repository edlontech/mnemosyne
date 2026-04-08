defmodule Mnemosyne.Pipeline.TagDeduplicator do
  @moduledoc """
  Deduplicates Tag nodes in a changeset against both the existing
  graph and other tags within the same batch.

  Tags are matched by normalized label (lowercase + trim). When a
  duplicate is found, the new tag is removed and all links referencing
  it are rewritten to point to the existing tag.
  """

  require Logger

  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node, as: NodeProtocol
  alias Mnemosyne.Graph.Node.Tag
  alias Mnemosyne.Graph.Similarity
  alias Mnemosyne.NodeMetadata

  @embedding_similarity_threshold 0.9

  @doc "Deduplicates Tag nodes in the changeset against both the batch and the existing graph."
  @spec deduplicate(Changeset.t(), keyword()) :: {:ok, Changeset.t()} | {:error, term()}
  def deduplicate(%Changeset{} = changeset, opts) do
    {tags, other_nodes} = Enum.split_with(changeset.additions, &match?(%Tag{}, &1))

    if tags == [] do
      {:ok, changeset}
    else
      repo_id = Keyword.get(opts, :repo_id)

      Mnemosyne.Telemetry.span(
        [:tag_deduplicator, :deduplicate],
        %{repo_id: repo_id, tag_count: length(tags)},
        fn ->
          {result, deduped_count} = do_deduplicate(tags, other_nodes, changeset, opts)
          {result, %{deduped: deduped_count}}
        end
      )
    end
  end

  defp do_deduplicate(tags, other_nodes, %Changeset{} = changeset, opts) do
    {kept_tags, rewrites} = deduplicate_batch(tags)
    {kept_tags, rewrites} = deduplicate_by_embedding(kept_tags, rewrites)

    rewrites = maybe_deduplicate_against_graph(kept_tags, rewrites, opts)

    {surviving_tags, rewrites} = remove_replaced_tags(kept_tags, rewrites)
    rewritten_links = rewrite_links(changeset.links, rewrites)
    deduped_links = Enum.uniq(rewritten_links)
    cleaned_metadata = clean_metadata(changeset.metadata, rewrites)

    result =
      {:ok,
       %Changeset{
         changeset
         | additions: other_nodes ++ surviving_tags,
           links: deduped_links,
           metadata: cleaned_metadata
       }}

    {result, map_size(rewrites)}
  end

  defp maybe_deduplicate_against_graph(kept_tags, rewrites, opts) do
    case fetch_graph_tags(opts) do
      {:ok, graph_tags} ->
        graph_lookup = build_graph_lookup(graph_tags)
        deduplicate_against_graph(kept_tags, graph_lookup, graph_tags, rewrites)

      :error ->
        rewrites
    end
  end

  defp normalize_label(label), do: label |> String.trim() |> String.downcase()

  defp deduplicate_batch(tags) do
    {kept, rewrites, _seen} =
      Enum.reduce(tags, {[], %{}, %{}}, fn tag, {acc, rw, seen} ->
        normalized = normalize_label(tag.label)

        case Map.get(seen, normalized) do
          nil ->
            {[tag | acc], rw, Map.put(seen, normalized, tag.id)}

          existing_id ->
            {acc, Map.put(rw, tag.id, existing_id), seen}
        end
      end)

    {Enum.reverse(kept), rewrites}
  end

  defp deduplicate_by_embedding(tags, rewrites) do
    {kept, new_rewrites} =
      Enum.reduce(tags, {[], rewrites}, fn tag, {acc, rw} ->
        case find_embedding_match(tag, acc) do
          nil ->
            {[tag | acc], rw}

          existing_id ->
            {acc, Map.put(rw, tag.id, existing_id)}
        end
      end)

    {Enum.reverse(kept), new_rewrites}
  end

  defp find_embedding_match(%Tag{embedding: nil}, _candidates), do: nil

  defp find_embedding_match(%Tag{} = tag, candidates) do
    candidates
    |> Enum.filter(&(&1.embedding != nil))
    |> Enum.find_value(fn existing ->
      score =
        Similarity.cosine_similarity(
          NodeProtocol.embedding(tag),
          NodeProtocol.embedding(existing)
        )

      if score >= @embedding_similarity_threshold do
        existing.id
      end
    end)
  end

  defp fetch_graph_tags(opts) do
    {backend_mod, backend_state} = Keyword.fetch!(opts, :backend)

    case backend_mod.get_nodes_by_type([:tag], backend_state) do
      {:ok, tags, _state} ->
        {:ok, tags}

      {:error, reason} ->
        Logger.warning("TagDeduplicator: failed to fetch graph tags: #{inspect(reason)}")
        :error
    end
  end

  defp build_graph_lookup(graph_tags) do
    Map.new(graph_tags, fn tag -> {normalize_label(tag.label), tag.id} end)
  end

  defp deduplicate_against_graph(kept_tags, graph_lookup, graph_tags, rewrites) do
    Enum.reduce(kept_tags, rewrites, fn tag, acc ->
      normalized = normalize_label(tag.label)

      case Map.get(graph_lookup, normalized) do
        nil ->
          maybe_embedding_match_graph(tag, graph_tags, acc)

        existing_id ->
          Map.put(acc, tag.id, existing_id)
      end
    end)
  end

  defp maybe_embedding_match_graph(%Tag{embedding: nil}, _graph_tags, rewrites), do: rewrites

  defp maybe_embedding_match_graph(%Tag{} = tag, graph_tags, rewrites) do
    case find_embedding_match(tag, graph_tags) do
      nil -> rewrites
      existing_id -> Map.put(rewrites, tag.id, existing_id)
    end
  end

  defp remove_replaced_tags(tags, rewrites) do
    surviving = Enum.reject(tags, &Map.has_key?(rewrites, &1.id))
    {surviving, rewrites}
  end

  defp rewrite_links(links, rewrites) do
    Enum.map(links, fn {from, to, type} ->
      {Map.get(rewrites, from, from), Map.get(rewrites, to, to), type}
    end)
  end

  defp clean_metadata(metadata, rewrites) do
    Enum.reduce(rewrites, metadata, fn {source_id, target_id}, acc ->
      propagate_reward(acc, source_id, target_id)
    end)
  end

  defp propagate_reward(metadata, source_id, target_id) do
    case Map.get(metadata, source_id) do
      %NodeMetadata{cumulative_reward: reward} ->
        target_meta = Map.get(metadata, target_id, NodeMetadata.new())
        updated_target = NodeMetadata.update_reward(target_meta, reward)

        metadata
        |> Map.delete(source_id)
        |> Map.put(target_id, updated_target)

      nil ->
        Map.delete(metadata, source_id)
    end
  end
end
