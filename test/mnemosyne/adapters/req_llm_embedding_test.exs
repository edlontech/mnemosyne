defmodule Mnemosyne.Adapters.ReqLLMEmbeddingTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Adapters.ReqLLMEmbedding, as: Adapter
  alias Mnemosyne.Embedding.Response
  alias Mnemosyne.Errors.Framework.AdapterError

  test "embed returns a single vector with usage and forwards dimensions and provider options" do
    http_adapter = fn req ->
      request = req.body |> IO.iodata_to_binary() |> Jason.decode!()
      assert request["input"] == ["hello world"]
      assert request["model"] == "text-embedding-3-small"
      assert request["dimensions"] == 3
      assert request["user"] == "test-user"
      assert request["encoding_format"] == "float"

      {req, Req.Response.new(status: 200, body: embedding_response([[0.1, 0.2, 0.3]]))}
    end

    assert {:ok, %Response{} = response} =
             Adapter.embed("hello world", opts(http_adapter, dimensions: 3, user: "test-user"))

    assert response.vectors == [[0.1, 0.2, 0.3]]
    assert response.model == "openai:text-embedding-3-small"
    assert response.usage.input_tokens == 5
    assert is_number(response.usage.total_cost)
  end

  test "embed_batch restores input order from indexed provider results" do
    http_adapter = fn req ->
      request = req.body |> IO.iodata_to_binary() |> Jason.decode!()
      assert request["input"] == ["hello", "world"]

      body =
        embedding_response([[0.1, 0.2], [0.3, 0.4]])
        |> Map.update!("data", &Enum.reverse/1)

      {req, Req.Response.new(status: 200, body: body)}
    end

    assert {:ok, %Response{} = response} =
             Adapter.embed_batch(["hello", "world"], opts(http_adapter))

    assert response.vectors == [[0.1, 0.2], [0.3, 0.4]]
    assert response.model == "openai:text-embedding-3-small"
    assert response.usage.input_tokens == 5
  end

  test "emits single and batch telemetry while keeping float vectors and usage enabled" do
    attach_telemetry()

    http_adapter = fn req ->
      request = req.body |> IO.iodata_to_binary() |> Jason.decode!()
      assert request["encoding_format"] == "float"
      {req, Req.Response.new(status: 200, body: embedding_response([[0.1, 0.2]]))}
    end

    for {operation, input} <- [embed: "hello", embed_batch: ["hello"]] do
      assert {:ok, %Response{vectors: [[0.1, 0.2]], usage: usage}} =
               apply(Adapter, operation, [
                 input,
                 opts(http_adapter, return_usage: false, encoding_format: "base64")
               ])

      assert usage.input_tokens == 5
      assert usage.cache_read_input_tokens == 0
      assert usage.cache_creation_input_tokens == 0
      refute Enum.any?(usage, fn {_key, value} -> is_nil(value) end)

      start_event = [:mnemosyne, :embedding, operation, :start]
      stop_event = [:mnemosyne, :embedding, operation, :stop]
      assert_receive {:telemetry, ^start_event, _, %{model: "openai:text-embedding-3-small"}}
      assert_receive {:telemetry, ^stop_event, measurements, metadata}
      assert is_integer(measurements.duration)

      if operation == :embed do
        assert metadata.text_length == 5
      else
        assert measurements.batch_size == 1
      end
    end
  end

  test "wraps provider errors for both callbacks and emits failure stop events" do
    attach_telemetry()

    http_adapter = fn req ->
      {req,
       Req.Response.new(
         status: 401,
         body: %{"error" => %{"message" => "Invalid API key", "type" => "invalid_request_error"}}
       )}
    end

    for {operation, input} <- [embed: "hello", embed_batch: ["hello"]] do
      assert {:error, %AdapterError{} = error} =
               apply(Adapter, operation, [input, opts(http_adapter)])

      assert error.adapter == Adapter
      assert error.operation == operation
      assert %{status: 401} = error.reason

      stop_event = [:mnemosyne, :embedding, operation, :stop]
      assert_receive {:telemetry, ^stop_event, measurements, _}
      assert is_integer(measurements.duration)
      refute Map.has_key?(measurements, :batch_size)
    end
  end

  defp attach_telemetry do
    handler_id = {__MODULE__, self()}

    events =
      for operation <- [:embed, :embed_batch], event <- [:start, :stop] do
        [:mnemosyne, :embedding, operation, event]
      end

    :ok = :telemetry.attach_many(handler_id, events, &__MODULE__.handle_event/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  @doc false
  def handle_event(event, measurements, metadata, owner) do
    if self() == owner, do: send(owner, {:telemetry, event, measurements, metadata})
  end

  @doc false
  def run(req), do: Process.get({__MODULE__, :http_adapter}).(req)

  defp opts(http_adapter, extra \\ []) do
    Process.put({__MODULE__, :http_adapter}, http_adapter)

    Keyword.merge(
      [
        model: "openai:text-embedding-3-small",
        api_key: "test-key",
        req_http_options: [adapter: __MODULE__, retry: false]
      ],
      extra
    )
  end

  defp embedding_response(vectors) do
    %{
      "object" => "list",
      "model" => "text-embedding-3-small",
      "data" =>
        vectors
        |> Enum.with_index()
        |> Enum.map(fn {vector, index} ->
          %{"object" => "embedding", "index" => index, "embedding" => vector}
        end),
      "usage" => %{"prompt_tokens" => 5, "total_tokens" => 5}
    }
  end
end
