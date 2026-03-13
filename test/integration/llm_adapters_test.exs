defmodule Mnemosyne.Integration.LlmAdaptersTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Mnemosyne.Adapters.SycophantLLM
  alias Mnemosyne.IntegrationHelpers
  alias Mnemosyne.LLM

  setup_all do
    api_key = IntegrationHelpers.ensure_openrouter_key!()
    %{api_key: api_key}
  end

  describe "SycophantLLM" do
    @tag timeout: 30_000
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

    @tag timeout: 30_000
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
end
