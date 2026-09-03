defmodule Mnemosyne.ModelCallTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Mnemosyne.Embedding.Response, as: EmbeddingResponse
  alias Mnemosyne.LLM.Response, as: LLMResponse
  alias Mnemosyne.ModelCall
  alias Mnemosyne.ModelCall.Context

  setup :set_mimic_global

  setup do
    test_pid = self()
    handler_id = "model-call-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:mnemosyne, :model, :call, :start],
        [:mnemosyne, :model, :call, :stop],
        [:mnemosyne, :model, :call, :exception]
      ],
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "chat forwards the adapter result and emits an attributed terminal event" do
    messages = [%{role: :user, content: "hello"}]
    opts = [model: "requested-model"]

    result =
      {:ok,
       %LLMResponse{
         content: "hello",
         model: "response-model",
         usage: %{input_tokens: 3, output_tokens: 2}
       }}

    expect(Mnemosyne.MockLLM, :chat, fn ^messages, ^opts -> result end)

    context = %Context{
      repo_id: "repo-1",
      operation: :ingest,
      source_id: "source-1",
      labels: %{environment: "test"}
    }

    assert ModelCall.chat(context, Mnemosyne.MockLLM, :get_state, messages, opts) == result

    assert_receive {:telemetry, [:mnemosyne, :model, :call, :start], _, start_metadata}

    assert start_metadata == %{
             repo_id: "repo-1",
             operation: :ingest,
             source_id: "source-1",
             labels: %{environment: "test"},
             kind: :llm,
             callback: :chat,
             adapter: Mnemosyne.MockLLM,
             step: :get_state,
             requested_model: "requested-model"
           }

    assert_receive {:telemetry, [:mnemosyne, :model, :call, :stop], measurements, metadata}
    assert measurements.input_tokens == 3
    assert measurements.output_tokens == 2
    assert metadata.status == :ok
    assert metadata.response_model == "response-model"
  end

  test "chat_structured keeps recognized usage values and terminal model metadata" do
    messages = [%{role: :user, content: "extract"}]
    schema = %{type: :object}
    opts = [model: "requested-model"]

    usage = %{
      input_tokens: 0,
      output_tokens: 2,
      cache_creation_input_tokens: 3,
      cache_read_input_tokens: 4,
      reasoning_tokens: 5,
      input_cost: 0,
      output_cost: 0.2,
      cache_read_cost: 0.3,
      cache_write_cost: 0.4,
      reasoning_cost: 0.5,
      total_cost: 1.4,
      currency: "USD",
      provider_field: "ignored"
    }

    result =
      {:ok, %LLMResponse{content: %{facts: []}, model: nil, usage: usage}}

    expect(Mnemosyne.MockLLM, :chat_structured, fn ^messages, ^schema, ^opts -> result end)

    context = %Context{repo_id: "repo-1", operation: :ingest}

    assert ModelCall.chat_structured(
             context,
             Mnemosyne.MockLLM,
             :get_semantic,
             messages,
             schema,
             opts
           ) == result

    assert_receive {:telemetry, [:mnemosyne, :model, :call, :stop], measurements, metadata}

    assert Map.take(measurements, Map.keys(usage) -- [:currency, :provider_field]) ==
             Map.drop(usage, [:currency, :provider_field])

    refute Map.has_key?(measurements, :provider_field)
    assert metadata.status == :ok
    assert metadata.requested_model == "requested-model"
    assert metadata.response_model == "requested-model"
    assert metadata.currency == "USD"
  end

  test "embed and embed_batch forward their adapter inputs" do
    text = "embed me"
    texts = [text, "and me"]
    opts = [model: "embedding-model"]
    single_result = {:ok, %EmbeddingResponse{vectors: [[0.1]], model: "embed-1", usage: %{}}}

    batch_result =
      {:ok, %EmbeddingResponse{vectors: [[0.1], [0.2]], model: "embed-2", usage: %{}}}

    expect(Mnemosyne.MockEmbedding, :embed, fn ^text, ^opts -> single_result end)
    expect(Mnemosyne.MockEmbedding, :embed_batch, fn ^texts, ^opts -> batch_result end)

    context = %Context{repo_id: "repo-1", operation: :recall}

    assert ModelCall.embed(context, Mnemosyne.MockEmbedding, :retrieval, text, opts) ==
             single_result

    assert_receive {:telemetry, [:mnemosyne, :model, :call, :stop], _,
                    %{kind: :embedding, callback: :embed, step: :retrieval}}

    assert ModelCall.embed_batch(context, Mnemosyne.MockEmbedding, :retrieval, texts, opts) ==
             batch_result

    assert_receive {:telemetry, [:mnemosyne, :model, :call, :stop], _,
                    %{kind: :embedding, callback: :embed_batch, step: :retrieval}}
  end

  test "returned adapter errors emit an error terminal event unchanged" do
    opts = [model: "requested-model"]
    result = {:error, :rate_limited}
    expect(Mnemosyne.MockLLM, :chat, fn _messages, ^opts -> result end)

    assert ModelCall.chat(context(), Mnemosyne.MockLLM, :get_state, [], opts) == result

    assert_receive {:telemetry, [:mnemosyne, :model, :call, :stop], measurements, metadata}
    assert Map.keys(measurements) |> Enum.sort() == [:duration, :monotonic_time]
    assert metadata.status == :error
    assert metadata.response_model == "requested-model"
    refute Map.has_key?(metadata, :currency)
  end

  test "nil, non-map, and malformed usage do not affect adapter results" do
    opts = [model: "requested-model"]

    responses = %{
      nil: {:ok, %LLMResponse{content: "nil", model: "response", usage: nil}},
      empty: {:ok, %LLMResponse{content: "empty", model: "response", usage: %{}}},
      non_map: {:ok, %LLMResponse{content: "non-map", model: "response", usage: :unknown}},
      malformed:
        {:ok,
         %LLMResponse{
           content: "malformed",
           model: "response",
           usage: %{input_tokens: -1, output_tokens: 1.5, input_cost: "0.2", currency: 1}
         }}
    }

    stub(Mnemosyne.MockLLM, :chat, fn _messages, opts ->
      Map.fetch!(responses, Keyword.fetch!(opts, :usage_case))
    end)

    Enum.each(responses, fn {usage_case, result} ->
      assert ModelCall.chat(
               context(),
               Mnemosyne.MockLLM,
               :get_state,
               [],
               opts ++ [usage_case: usage_case]
             ) ==
               result

      assert_receive {:telemetry, [:mnemosyne, :model, :call, :stop], measurements, metadata}
      assert Map.keys(measurements) |> Enum.sort() == [:duration, :monotonic_time]
      refute Map.has_key?(metadata, :currency)
    end)
  end

  test "nil context calls the adapter without model-call telemetry" do
    opts = [model: "requested-model"]
    result = {:ok, %LLMResponse{content: "direct", model: "response", usage: %{}}}
    expect(Mnemosyne.MockLLM, :chat, fn _messages, ^opts -> result end)

    assert ModelCall.chat(nil, Mnemosyne.MockLLM, :get_state, [], opts) == result

    refute_receive {:telemetry, [:mnemosyne, :model, :call, _], _, _}
  end

  test "raised adapter calls emit one exception event and preserve the exception" do
    stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts -> raise "boom" end)

    assert_raise RuntimeError, "boom", fn ->
      ModelCall.chat(context(), Mnemosyne.MockLLM, :get_state, [], model: "requested-model")
    end

    assert_receive {:telemetry, [:mnemosyne, :model, :call, :exception], _, metadata}
    assert metadata.status == :exception
    assert metadata.kind == :llm
    assert metadata.exception_kind == :error
    refute_receive {:telemetry, [:mnemosyne, :model, :call, :stop], _, _}
    refute_receive {:telemetry, [:mnemosyne, :model, :call, :exception], _, _}
  end

  test "thrown and exited adapter calls emit exception events and preserve their failures" do
    stub(Mnemosyne.MockLLM, :chat, fn _messages, opts ->
      case Keyword.fetch!(opts, :failure) do
        :throw -> throw(:boom)
        :exit -> exit(:boom)
      end
    end)

    assert catch_throw(
             ModelCall.chat(context(), Mnemosyne.MockLLM, :get_state, [],
               model: "requested-model",
               failure: :throw
             )
           ) == :boom

    assert_receive {:telemetry, [:mnemosyne, :model, :call, :exception], _, throw_metadata}
    assert throw_metadata.status == :exception
    assert throw_metadata.kind == :llm
    assert throw_metadata.exception_kind == :throw

    assert catch_exit(
             ModelCall.chat(context(), Mnemosyne.MockLLM, :get_state, [],
               model: "requested-model",
               failure: :exit
             )
           ) == :boom

    assert_receive {:telemetry, [:mnemosyne, :model, :call, :exception], _, exit_metadata}
    assert exit_metadata.status == :exception
    assert exit_metadata.kind == :llm
    assert exit_metadata.exception_kind == :exit
    refute_receive {:telemetry, [:mnemosyne, :model, :call, :stop], _, _}
    refute_receive {:telemetry, [:mnemosyne, :model, :call, :exception], _, _}
  end

  defp context do
    %Context{repo_id: "repo-1", operation: :ingest, labels: %{environment: "test"}}
  end
end
