defmodule Mnemosyne.Integration.AdaptersTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Mnemosyne.Adapters.BumblebeeEmbedding
  alias Mnemosyne.Adapters.SycophantLLM
  alias Mnemosyne.Embedding
  alias Mnemosyne.Graph.Similarity
  alias Mnemosyne.IntegrationHelpers
  alias Mnemosyne.LLM

  setup_all do
    IntegrationHelpers.setup_serving()
    api_key = IntegrationHelpers.ensure_openrouter_key!()
    %{api_key: api_key}
  end

  describe "SycophantLLM" do
    test "chat/2 returns a valid response from OpenRouter", %{api_key: api_key} do
      messages = [%{role: :user, content: "Reply with exactly one word: hello"}]

      opts = [
        model: IntegrationHelpers.llm_model(),
        credentials: %{api_key: api_key}
      ]

      assert {:ok, %LLM.Response{} = response} = SycophantLLM.chat(messages, opts)
      assert is_binary(response.content)
      assert String.length(response.content) > 0
      assert is_map(response.usage)
    end

    test "chat_structured/3 returns structured data matching the schema", %{api_key: api_key} do
      messages = [
        %{role: :user, content: "Analyze the sentiment of: 'I love sunny days'"}
      ]

      schema =
        Zoi.object(%{
          sentiment: Zoi.string(),
          confidence: Zoi.number()
        })

      opts = [
        model: IntegrationHelpers.llm_model(),
        credentials: %{api_key: api_key}
      ]

      assert {:ok, %LLM.Response{} = response} =
               SycophantLLM.chat_structured(messages, schema, opts)

      assert is_map(response.content)

      assert Map.has_key?(response.content, "sentiment") or
               Map.has_key?(response.content, :sentiment)

      assert Map.has_key?(response.content, "confidence") or
               Map.has_key?(response.content, :confidence)
    end
  end

  describe "BumblebeeEmbedding" do
    @embedding_opts [serving: Mnemosyne.IntegrationServing, model: "qwen3-0.6b"]

    test "embed/2 returns a vector of floats" do
      assert {:ok, %Embedding.Response{} = response} =
               BumblebeeEmbedding.embed("the cat sat on the mat", @embedding_opts)

      assert [vector] = response.vectors
      assert is_list(vector)
      assert length(vector) > 0
      assert Enum.all?(vector, &is_float/1)
    end

    test "embed_batch/2 returns matching-dimension vectors for all inputs" do
      texts = ["first sentence", "second sentence", "third sentence"]

      assert {:ok, %Embedding.Response{} = response} =
               BumblebeeEmbedding.embed_batch(texts, @embedding_opts)

      assert length(response.vectors) == 3
      [dim | _] = Enum.map(response.vectors, &length/1)
      assert Enum.all?(response.vectors, fn v -> length(v) == dim end)
    end

    test "similar texts have higher cosine similarity than dissimilar ones" do
      texts = [
        "the cat sat on the mat",
        "the dog sat on the rug",
        "quantum mechanics wave function equations"
      ]

      assert {:ok, %Embedding.Response{vectors: [v1, v2, v3]}} =
               BumblebeeEmbedding.embed_batch(texts, @embedding_opts)

      sim_related = Similarity.cosine_similarity(v1, v2)
      sim_unrelated = Similarity.cosine_similarity(v1, v3)

      assert sim_related > sim_unrelated,
             "Expected similar texts (#{sim_related}) to score higher than dissimilar (#{sim_unrelated})"
    end
  end
end
