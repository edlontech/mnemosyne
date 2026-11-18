defmodule Mnemosyne.Graph.Similarity do
  @moduledoc """
  Cosine similarity over embedding lists.

  Provides vector similarity scoring for knowledge graph node retrieval. The
  arithmetic runs directly on the lists: building a tensor per comparison made
  each call about twelve times slower, which dominated recall on large repos.
  """

  @doc """
  Computes cosine similarity between two vectors, returning a value in [-1, 1].

  Returns `0.0` when either vector is empty or all zeros. The vectors must have
  the same length.
  """
  @spec cosine_similarity([number()], [number()]) :: float()
  def cosine_similarity(a, b), do: cosine(a, b, 0.0, 0.0, 0.0)

  defp cosine([x | a], [y | b], dot, norm_a, norm_b),
    do: cosine(a, b, dot + x * y, norm_a + x * x, norm_b + y * y)

  defp cosine([], [], dot, norm_a, norm_b) do
    denominator = :math.sqrt(norm_a) * :math.sqrt(norm_b)

    if denominator == 0.0,
      do: 0.0,
      else: (dot / denominator) |> min(1.0) |> max(-1.0)
  end

  @doc "Returns the `k` most similar candidates to `query`, sorted by descending similarity."
  @spec top_k([float()], [{String.t(), [float()] | nil}], non_neg_integer()) ::
          [{String.t(), float()}]
  def top_k(query, candidates, k) do
    candidates
    |> Enum.reject(fn {_id, emb} -> is_nil(emb) end)
    |> Enum.map(fn {id, emb} -> {id, cosine_similarity(query, emb)} end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(k)
  end
end
