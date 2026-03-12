defmodule Mnemosyne.Graph.Similarity do
  @moduledoc """
  Cosine similarity computations using Scholar and Nx.

  Provides vector similarity scoring for knowledge graph node retrieval.
  """

  @doc "Computes cosine similarity between two vectors, returning a value in [-1, 1]."
  @spec cosine_similarity([float()], [float()]) :: float()
  def cosine_similarity([], []), do: 0.0

  def cosine_similarity(a, b) do
    x = Nx.tensor(a, type: :f32)
    y = Nx.tensor(b, type: :f32)

    distance =
      Scholar.Metrics.Distance.cosine(x, y)
      |> Nx.to_number()

    case distance do
      d when is_float(d) -> 1.0 - d
      _ -> 0.0
    end
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
