defmodule Mnemosyne.Adapters.SycophantEmbeddingTelemetryTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Mnemosyne.Adapters.SycophantEmbedding

  setup :set_mimic_global

  setup do
    test_pid = self()
    handler_id = "test-embed-tel-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:mnemosyne, :embedding, :embed, :start],
        [:mnemosyne, :embedding, :embed, :stop],
        [:mnemosyne, :embedding, :embed_batch, :start],
        [:mnemosyne, :embedding, :embed_batch, :stop]
      ],
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  describe "embed/2 telemetry" do
    test "emits start and stop events with text_length metadata" do
      usage = %Sycophant.Usage{
        input_tokens: 5,
        output_tokens: 0,
        cache_creation_input_tokens: 1,
        cache_read_input_tokens: 2,
        reasoning_tokens: 0,
        input_cost: 0.001,
        output_cost: 0.0,
        cache_read_cost: 0.0002,
        cache_write_cost: 0.0003,
        reasoning_cost: 0.0,
        total_cost: 0.0015,
        pricing: %Sycophant.Pricing{currency: "USD"}
      }

      expect(Sycophant, :embed, fn _request, _opts ->
        {:ok,
         %Sycophant.EmbeddingResponse{
           embeddings: %{float: [[0.1, 0.2, 0.3]]},
           model: "text-embedding-3-small",
           usage: usage
         }}
      end)

      assert {:ok, %{usage: translated_usage}} =
               SycophantEmbedding.embed("hello", model: "test-model")

      assert translated_usage == %{
               input_tokens: 5,
               output_tokens: 0,
               cache_creation_input_tokens: 1,
               cache_read_input_tokens: 2,
               reasoning_tokens: 0,
               input_cost: 0.001,
               output_cost: 0.0,
               cache_read_cost: 0.0002,
               cache_write_cost: 0.0003,
               reasoning_cost: 0.0,
               total_cost: 0.0015,
               currency: "USD"
             }

      assert_receive {:telemetry, [:mnemosyne, :embedding, :embed, :start], _,
                      %{model: "test-model", text_length: 5}}

      assert_receive {:telemetry, [:mnemosyne, :embedding, :embed, :stop], measurements,
                      %{model: "test-model"}}

      assert is_integer(measurements.duration)
    end

    test "emits stop event on error" do
      expect(Sycophant, :embed, fn _request, _opts ->
        {:error, :service_unavailable}
      end)

      assert {:error, :service_unavailable} =
               SycophantEmbedding.embed("hello", model: "test-model")

      assert_receive {:telemetry, [:mnemosyne, :embedding, :embed, :stop], measurements,
                      %{model: "test-model"}}

      assert is_integer(measurements.duration)
    end
  end

  describe "embed_batch/2 telemetry" do
    test "emits start and stop events with batch_size measurement" do
      expect(Sycophant, :embed, fn _request, _opts ->
        {:ok,
         %Sycophant.EmbeddingResponse{
           embeddings: %{float: [[0.1, 0.2], [0.3, 0.4], [0.5, 0.6]]},
           model: "text-embedding-3-small",
           usage: %Sycophant.Usage{input_tokens: 15}
         }}
      end)

      texts = ["hello", "world", "test"]
      assert {:ok, _} = SycophantEmbedding.embed_batch(texts, model: "test-model")

      assert_receive {:telemetry, [:mnemosyne, :embedding, :embed_batch, :start], _,
                      %{model: "test-model"}}

      assert_receive {:telemetry, [:mnemosyne, :embedding, :embed_batch, :stop], measurements,
                      %{model: "test-model"}}

      assert measurements.batch_size == 3
      assert is_integer(measurements.duration)
    end
  end
end
