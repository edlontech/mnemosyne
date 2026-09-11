defmodule Mnemosyne.Integration.ReqLLMAdaptersTest do
  use ExUnit.Case, async: false

  alias Mnemosyne.Adapters.ReqLLM, as: LLMAdapter
  alias Mnemosyne.Adapters.ReqLLMEmbedding, as: EmbeddingAdapter
  alias Mnemosyne.Embedding
  alias Mnemosyne.LLM

  @moduletag :integration
  @moduletag timeout: 60_000

  @llm_model "openrouter:google/gemini-3-flash-preview"
  @embedding_model "openrouter:openai/text-embedding-3-small"
  @dimensions 256

  setup do
    api_key = System.get_env("OPENROUTER_API_KEY")

    assert is_binary(api_key) and api_key != "",
           "OPENROUTER_API_KEY is required for integration tests"

    %{
      llm_opts: [model: @llm_model, api_key: api_key],
      embedding_opts: [model: @embedding_model, api_key: api_key, dimensions: @dimensions]
    }
  end

  test "chat returns text and usage from OpenRouter", %{llm_opts: opts} do
    messages = [%{role: :user, content: "Reply with exactly one word: hello"}]

    assert {:ok, %LLM.Response{} = response} = LLMAdapter.chat(messages, opts)
    assert is_binary(response.content)
    assert String.trim(response.content) != ""
    assert is_binary(response.model)
    assert is_integer(response.usage.input_tokens)
    assert is_integer(response.usage.output_tokens)
  end

  test "structured chat returns nested atom keys matching the Zoi schema", %{llm_opts: opts} do
    schema = Zoi.map(%{person: Zoi.map(%{name: Zoi.string(), age: Zoi.integer()})})
    messages = [%{role: :user, content: "Extract this person: Alice is 30 years old."}]

    assert {:ok, %LLM.Response{} = response} =
             LLMAdapter.chat_structured(messages, schema, opts)

    assert %{person: %{name: "Alice", age: 30}} = response.content
    assert is_map(response.usage)
  end

  test "embed returns a float vector with the requested dimensions and usage", %{
    embedding_opts: opts
  } do
    assert {:ok, %Embedding.Response{} = response} =
             EmbeddingAdapter.embed("the cat sat on the mat", opts)

    assert [vector] = response.vectors
    assert length(vector) == @dimensions
    assert Enum.all?(vector, &is_float/1)
    assert response.model == @embedding_model
    assert is_integer(response.usage.input_tokens)
  end

  test "embed_batch returns one matching-dimension vector per input", %{embedding_opts: opts} do
    texts = ["the cat sat on the mat", "quantum mechanics describes particles"]

    assert {:ok, %Embedding.Response{} = response} = EmbeddingAdapter.embed_batch(texts, opts)
    assert length(response.vectors) == length(texts)

    for vector <- response.vectors do
      assert length(vector) == @dimensions
      assert Enum.all?(vector, &is_float/1)
    end

    assert response.model == @embedding_model
    assert is_integer(response.usage.input_tokens)
  end
end
