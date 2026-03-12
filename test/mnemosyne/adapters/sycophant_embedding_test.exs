defmodule Mnemosyne.Adapters.SycophantEmbeddingTest do
  use ExUnit.Case, async: false
  use Mimic

  setup :set_mimic_global

  alias Mnemosyne.Adapters.SycophantEmbedding
  alias Mnemosyne.Embedding.Response

  describe "embed/2" do
    test "returns single vector" do
      vector = [0.1, 0.2, 0.3]
      usage = %Sycophant.Usage{input_tokens: 5}

      Mimic.expect(Sycophant, :embed, fn %Sycophant.EmbeddingRequest{} = req, _opts ->
        assert req.inputs == ["hello world"]
        assert req.model == "openai:text-embedding-3-small"

        {:ok,
         %Sycophant.EmbeddingResponse{
           embeddings: %{float: [vector]},
           model: "text-embedding-3-small",
           usage: usage
         }}
      end)

      assert {:ok, %Response{} = resp} =
               SycophantEmbedding.embed("hello world", model: "openai:text-embedding-3-small")

      assert resp.vectors == [vector]
      assert resp.model == "text-embedding-3-small"
      assert resp.usage == %{input_tokens: 5}
    end
  end

  describe "embed_batch/2" do
    test "returns multiple vectors" do
      vectors = [[0.1, 0.2], [0.3, 0.4]]
      usage = %Sycophant.Usage{input_tokens: 10}

      Mimic.expect(Sycophant, :embed, fn %Sycophant.EmbeddingRequest{} = req, _opts ->
        assert req.inputs == ["hello", "world"]

        {:ok,
         %Sycophant.EmbeddingResponse{
           embeddings: %{float: vectors},
           model: "text-embedding-3-small",
           usage: usage
         }}
      end)

      assert {:ok, %Response{} = resp} =
               SycophantEmbedding.embed_batch(
                 ["hello", "world"],
                 model: "openai:text-embedding-3-small"
               )

      assert resp.vectors == vectors
      assert resp.model == "text-embedding-3-small"
    end
  end

  describe "dimensions parameter" do
    test "passes dimensions param when provided" do
      Mimic.expect(Sycophant, :embed, fn %Sycophant.EmbeddingRequest{} = req, _opts ->
        assert req.params != nil
        assert req.params.dimensions == 256

        {:ok,
         %Sycophant.EmbeddingResponse{
           embeddings: %{float: [[0.1, 0.2]]},
           model: "text-embedding-3-small",
           usage: nil
         }}
      end)

      assert {:ok, _resp} =
               SycophantEmbedding.embed(
                 "hello",
                 model: "openai:text-embedding-3-small",
                 dimensions: 256
               )
    end
  end

  describe "error handling" do
    test "propagates errors from Sycophant" do
      Mimic.expect(Sycophant, :embed, fn _req, _opts ->
        {:error, :provider_error}
      end)

      assert {:error, :provider_error} =
               SycophantEmbedding.embed("hello", model: "openai:text-embedding-3-small")
    end
  end
end
