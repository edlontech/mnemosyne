defmodule Mnemosyne.Integration.EmbeddingAdaptersTest do
  use Mnemosyne.IntegrationCase, async: false

  alias Mnemosyne.Adapters.BumblebeeEmbedding
  alias Mnemosyne.Embedding
  alias Mnemosyne.Graph.Similarity

  describe "BumblebeeEmbedding" do
    test "embed/2 returns a vector of floats", %{serving: serving, embedding_model: model} do
      opts = [serving: serving, model: model]

      assert {:ok, %Embedding.Response{} = response} =
               BumblebeeEmbedding.embed("the cat sat on the mat", opts)

      assert [vector] = response.vectors
      assert is_list(vector)
      assert vector != []
      assert Enum.all?(vector, &is_float/1)
    end

    test "embed_batch/2 returns matching-dimension vectors for all inputs", %{
      serving: serving,
      embedding_model: model
    } do
      texts = ["first sentence", "second sentence", "third sentence"]
      opts = [serving: serving, model: model]

      assert {:ok, %Embedding.Response{} = response} =
               BumblebeeEmbedding.embed_batch(texts, opts)

      assert length(response.vectors) == 3
      [dim | _] = Enum.map(response.vectors, &length/1)
      assert Enum.all?(response.vectors, fn v -> length(v) == dim end)
    end

    test "similar texts have higher cosine similarity than dissimilar ones", %{
      serving: serving,
      embedding_model: model
    } do
      texts = [
        "the cat sat on the mat",
        "the dog sat on the rug",
        "quantum mechanics wave function equations"
      ]

      opts = [serving: serving, model: model]

      assert {:ok, %Embedding.Response{vectors: [v1, v2, v3]}} =
               BumblebeeEmbedding.embed_batch(texts, opts)

      sim_related = Similarity.cosine_similarity(v1, v2)
      sim_unrelated = Similarity.cosine_similarity(v1, v3)

      assert sim_related > sim_unrelated,
             "Expected similar texts (#{sim_related}) to score higher than dissimilar (#{sim_unrelated})"
    end
  end
end
