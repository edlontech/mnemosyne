defmodule Mnemosyne.Adapters.SycophantLLMTelemetryTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Mnemosyne.Adapters.SycophantLLM

  @context %Sycophant.Context{messages: []}

  setup :set_mimic_global

  setup do
    test_pid = self()
    handler_id = "test-llm-tel-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:mnemosyne, :llm, :chat, :start],
        [:mnemosyne, :llm, :chat, :stop],
        [:mnemosyne, :llm, :chat_structured, :start],
        [:mnemosyne, :llm, :chat_structured, :stop]
      ],
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  describe "chat/2 telemetry" do
    test "emits start and stop events with token measurements" do
      usage = %Sycophant.Usage{input_tokens: 50, output_tokens: 20}

      expect(Sycophant, :generate_text, fn _model, _msgs, _opts ->
        {:ok,
         %Sycophant.Response{
           text: "hello",
           model: "gpt-4o-mini",
           usage: usage,
           context: @context
         }}
      end)

      assert {:ok, _} = SycophantLLM.chat([%{role: :user, content: "hi"}], model: "test-model")

      assert_receive {:telemetry, [:mnemosyne, :llm, :chat, :start], _, %{model: "test-model"}}

      assert_receive {:telemetry, [:mnemosyne, :llm, :chat, :stop], measurements,
                      %{model: "test-model"}}

      assert measurements.tokens_input == 50
      assert measurements.tokens_output == 20
      assert is_integer(measurements.duration)
    end

    test "emits stop event with empty measurements on error" do
      expect(Sycophant, :generate_text, fn _model, _msgs, _opts ->
        {:error, :rate_limited}
      end)

      assert {:error, :rate_limited} =
               SycophantLLM.chat([%{role: :user, content: "hi"}], model: "test-model")

      assert_receive {:telemetry, [:mnemosyne, :llm, :chat, :stop], measurements,
                      %{model: "test-model"}}

      assert is_integer(measurements.duration)
      refute Map.has_key?(measurements, :tokens_input)
    end

    test "includes step in metadata when provided" do
      expect(Sycophant, :generate_text, fn _model, _msgs, _opts ->
        {:ok,
         %Sycophant.Response{
           text: "ok",
           model: "gpt-4o-mini",
           usage: %Sycophant.Usage{input_tokens: 1, output_tokens: 1},
           context: @context
         }}
      end)

      assert {:ok, _} =
               SycophantLLM.chat([%{role: :user, content: "hi"}],
                 model: "test-model",
                 step: :summarize
               )

      assert_receive {:telemetry, [:mnemosyne, :llm, :chat, :stop], _,
                      %{model: "test-model", step: :summarize}}
    end
  end

  describe "chat_structured/3 telemetry" do
    test "emits start and stop events with token measurements" do
      usage = %Sycophant.Usage{input_tokens: 30, output_tokens: 10}
      schema = %{type: :object}

      expect(Sycophant, :generate_object, fn _model, _msgs, _schema, _opts ->
        {:ok,
         %Sycophant.Response{
           object: %{name: "Alice"},
           model: "gpt-4o-mini",
           usage: usage,
           context: @context
         }}
      end)

      assert {:ok, _} =
               SycophantLLM.chat_structured(
                 [%{role: :user, content: "hi"}],
                 schema,
                 model: "test-model"
               )

      assert_receive {:telemetry, [:mnemosyne, :llm, :chat_structured, :start], _,
                      %{model: "test-model", schema: ^schema}}

      assert_receive {:telemetry, [:mnemosyne, :llm, :chat_structured, :stop], measurements,
                      %{model: "test-model", schema: ^schema}}

      assert measurements.tokens_input == 30
      assert measurements.tokens_output == 10
      assert is_integer(measurements.duration)
    end

    test "emits stop event with empty measurements on error" do
      expect(Sycophant, :generate_object, fn _model, _msgs, _schema, _opts ->
        {:error, :invalid_schema}
      end)

      assert {:error, :invalid_schema} =
               SycophantLLM.chat_structured(
                 [%{role: :user, content: "hi"}],
                 %{type: :object},
                 model: "test-model"
               )

      assert_receive {:telemetry, [:mnemosyne, :llm, :chat_structured, :stop], measurements,
                      %{model: "test-model"}}

      assert is_integer(measurements.duration)
      refute Map.has_key?(measurements, :tokens_input)
    end
  end
end
