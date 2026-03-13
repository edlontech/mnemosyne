defmodule Mnemosyne.Integration.LlmAdaptersTest do
  use Mnemosyne.IntegrationCase, async: false

  alias Mnemosyne.Adapters.SycophantLLM
  alias Mnemosyne.LLM

  describe "SycophantLLM" do
    @tag timeout: 30_000
    test "chat/2 returns a valid response from OpenRouter", %{api_key: api_key, llm_model: model} do
      messages = [%{role: :user, content: "Reply with exactly one word: hello"}]

      opts = [
        model: model,
        credentials: %{api_key: api_key}
      ]

      assert {:ok, %LLM.Response{} = response} = SycophantLLM.chat(messages, opts)
      assert is_binary(response.content)
      assert String.length(response.content) > 0
      assert is_map(response.usage)
    end

    @tag timeout: 30_000
    test "chat_structured/3 returns structured data matching the schema", %{
      api_key: api_key,
      llm_model: model
    } do
      messages = [
        %{role: :user, content: "Analyze the sentiment of: 'I love sunny days'"}
      ]

      schema =
        Zoi.map(
          %{
            sentiment: Zoi.string(),
            confidence: Zoi.number()
          },
          coerce: true
        )

      opts = [
        model: model,
        credentials: %{api_key: api_key}
      ]

      assert {:ok, %LLM.Response{} = response} =
               SycophantLLM.chat_structured(messages, schema, opts)

      assert %{sentiment: sentiment, confidence: confidence} = response.content
      assert is_binary(sentiment)
      assert is_number(confidence)
    end
  end
end
