defmodule Mnemosyne.Graph.SimilarityTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Graph.Similarity

  describe "cosine_similarity/2" do
    test "identical vectors return ~1.0" do
      assert_in_delta Similarity.cosine_similarity([1.0, 2.0, 3.0], [1.0, 2.0, 3.0]), 1.0, 0.001
    end

    test "orthogonal vectors return ~0.0" do
      assert_in_delta Similarity.cosine_similarity([1.0, 0.0], [0.0, 1.0]), 0.0, 0.001
    end

    test "opposite vectors return ~-1.0" do
      assert_in_delta Similarity.cosine_similarity([1.0, 0.0], [-1.0, 0.0]), -1.0, 0.001
    end

    test "empty vectors return 0.0" do
      assert Similarity.cosine_similarity([], []) == 0.0
    end
  end

  describe "top_k/3" do
    test "returns correct ordering and count" do
      query = [1.0, 0.0, 0.0]

      candidates = [
        {"a", [1.0, 0.0, 0.0]},
        {"b", [0.0, 1.0, 0.0]},
        {"c", [0.7, 0.7, 0.0]}
      ]

      result = Similarity.top_k(query, candidates, 2)

      assert length(result) == 2
      assert [{"a", score_a}, {"c", score_c}] = result
      assert_in_delta score_a, 1.0, 0.001
      assert score_c > 0.0
    end

    test "skips nil embeddings" do
      query = [1.0, 0.0]

      candidates = [
        {"a", [1.0, 0.0]},
        {"b", nil},
        {"c", [0.0, 1.0]}
      ]

      result = Similarity.top_k(query, candidates, 3)

      ids = Enum.map(result, &elem(&1, 0))
      assert "a" in ids
      assert "c" in ids
      refute "b" in ids
    end
  end
end
