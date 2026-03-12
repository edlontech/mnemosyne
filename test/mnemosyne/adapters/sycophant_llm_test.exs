defmodule Mnemosyne.Adapters.SycophantLLMTest do
  use ExUnit.Case, async: false
  use Mimic

  setup :set_mimic_global

  alias Mnemosyne.Adapters.SycophantLLM
  alias Mnemosyne.LLM.Response

  @context %Sycophant.Context{messages: []}

  describe "chat/2" do
    test "translates messages and extracts text and usage" do
      usage = %Sycophant.Usage{input_tokens: 10, output_tokens: 20}

      Mimic.expect(Sycophant, :generate_text, fn model, messages, opts ->
        assert model == "openai:gpt-4o-mini"
        assert [%Sycophant.Message{role: :system}, %Sycophant.Message{role: :user}] = messages
        assert opts == [temperature: 0.5]

        {:ok,
         %Sycophant.Response{
           text: "Hello there",
           model: "gpt-4o-mini",
           usage: usage,
           context: @context
         }}
      end)

      messages = [
        %{role: :system, content: "Be helpful"},
        %{role: :user, content: "Hi"}
      ]

      assert {:ok, %Response{} = resp} =
               SycophantLLM.chat(messages, model: "openai:gpt-4o-mini", temperature: 0.5)

      assert resp.content == "Hello there"
      assert resp.model == "gpt-4o-mini"
      assert resp.usage == %{input_tokens: 10, output_tokens: 20}
    end

    test "propagates errors from Sycophant" do
      Mimic.expect(Sycophant, :generate_text, fn _model, _messages, _opts ->
        {:error, :rate_limited}
      end)

      assert {:error, :rate_limited} =
               SycophantLLM.chat(
                 [%{role: :user, content: "Hi"}],
                 model: "openai:gpt-4o-mini"
               )
    end
  end

  describe "chat_structured/3" do
    test "delegates to generate_object and extracts object" do
      usage = %Sycophant.Usage{input_tokens: 5, output_tokens: 15}
      schema = %{type: :object}

      Mimic.expect(Sycophant, :generate_object, fn model, messages, s, opts ->
        assert model == "openai:gpt-4o-mini"
        assert [%Sycophant.Message{role: :user}] = messages
        assert s == schema
        assert opts == []

        {:ok,
         %Sycophant.Response{
           object: %{name: "Alice", age: 25},
           model: "gpt-4o-mini",
           usage: usage,
           context: @context
         }}
      end)

      messages = [%{role: :user, content: "Extract: Alice is 25"}]

      assert {:ok, %Response{} = resp} =
               SycophantLLM.chat_structured(messages, schema, model: "openai:gpt-4o-mini")

      assert resp.content == %{name: "Alice", age: 25}
      assert resp.model == "gpt-4o-mini"
      assert resp.usage == %{input_tokens: 5, output_tokens: 15}
    end

    test "propagates errors from Sycophant" do
      Mimic.expect(Sycophant, :generate_object, fn _model, _messages, _schema, _opts ->
        {:error, :invalid_schema}
      end)

      assert {:error, :invalid_schema} =
               SycophantLLM.chat_structured(
                 [%{role: :user, content: "Hi"}],
                 %{type: :object},
                 model: "openai:gpt-4o-mini"
               )
    end
  end
end
