defmodule Mnemosyne.Adapters.ReqLLMTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Adapters.ReqLLM, as: Adapter
  alias Mnemosyne.Errors.Framework.AdapterError
  alias Mnemosyne.LLM.Response
  alias Mnemosyne.Pipeline.Prompts.GetSemantic

  test "chat preserves messages and options and extracts text and usage" do
    http_adapter = fn req ->
      request = req.body |> IO.iodata_to_binary() |> Jason.decode!()

      assert request["model"] == "gpt-4o-mini"
      assert request["max_output_tokens"] == 100

      assert request["input"] == [
               %{
                 "role" => "system",
                 "content" => [%{"type" => "input_text", "text" => "Be helpful"}]
               },
               %{"role" => "user", "content" => [%{"type" => "input_text", "text" => "Hi"}]},
               %{
                 "role" => "assistant",
                 "content" => [%{"type" => "output_text", "text" => "Hello"}]
               },
               %{"role" => "user", "content" => [%{"type" => "input_text", "text" => "Continue"}]}
             ]

      {req, Req.Response.new(status: 200, body: completion("Hello there"))}
    end

    messages = [
      %{role: :system, content: "Be helpful"},
      %{role: :user, content: "Hi"},
      %{role: :assistant, content: "Hello"},
      %{role: :user, content: "Continue"}
    ]

    assert {:ok, %Response{} = response} =
             Adapter.chat(messages, opts(http_adapter, max_tokens: 100))

    assert response.content == "Hello there"
    assert response.model == "gpt-4o-mini"
    assert response.usage.input_tokens == 10
    assert response.usage.output_tokens == 20
  end

  test "chat_structured returns schema-parsed nested content for pipeline prompts" do
    schema = GetSemantic.schema()

    http_adapter = fn req ->
      request = req.body |> IO.iodata_to_binary() |> Jason.decode!()
      assert get_in(request, ["text", "format", "type"]) == "json_schema"
      assert get_in(request, ["text", "format", "schema", "properties", "facts"])

      object = %{
        "facts" => [
          %{
            "proposition" => "Alice uses Elixir",
            "concepts" => ["Elixir"],
            "confidence" => 0.9,
            "source_steps" => [1]
          }
        ]
      }

      {req, Req.Response.new(status: 200, body: completion(Jason.encode!(object)))}
    end

    assert {:ok, %Response{} = response} =
             Adapter.chat_structured(
               [%{role: :user, content: "Alice uses Elixir"}],
               schema,
               opts(http_adapter)
             )

    assert response.content == %{
             facts: [
               %{
                 proposition: "Alice uses Elixir",
                 concepts: ["Elixir"],
                 confidence: 0.9,
                 source_steps: [1]
               }
             ]
           }

    assert response.model == "gpt-4o-mini"
    assert response.usage.input_tokens == 10
    assert response.usage.output_tokens == 20
  end

  test "wraps provider errors for both callbacks without losing the reason" do
    attach_telemetry()

    http_adapter = fn req ->
      {req,
       Req.Response.new(
         status: 401,
         body: %{"error" => %{"message" => "Invalid API key", "type" => "invalid_request_error"}}
       )}
    end

    for operation <- [:chat, :chat_structured] do
      messages = [%{role: :user, content: "Hi"}]

      args =
        if operation == :chat, do: [messages], else: [messages, Zoi.map(%{name: Zoi.string()})]

      assert {:error, %AdapterError{} = error} =
               apply(Adapter, operation, args ++ [opts(http_adapter)])

      assert error.adapter == Adapter
      assert error.operation == operation
      assert %{status: 401} = error.reason

      stop_event = [:mnemosyne, :llm, operation, :stop]
      assert_receive {:telemetry, ^stop_event, measurements, _}
      assert is_integer(measurements.duration)
      refute Map.has_key?(measurements, :tokens_input)
      refute Map.has_key?(measurements, :tokens_output)
    end
  end

  test "both callbacks emit telemetry and normalize cache, reasoning, and cost usage" do
    attach_telemetry()

    http_adapter = fn req ->
      body =
        completion(~s({"name":"Alice"}))
        |> Map.put("usage", %{
          "input_tokens" => 10,
          "output_tokens" => 20,
          "total_tokens" => 30,
          "input_tokens_details" => %{"cached_tokens" => 4},
          "output_tokens_details" => %{"reasoning_tokens" => 5}
        })

      {req, Req.Response.new(status: 200, body: body)}
    end

    schema = Zoi.map(%{name: Zoi.string()}, coerce: true)
    messages = [%{role: :user, content: "Hi"}]

    for operation <- [:chat, :chat_structured] do
      args = if operation == :chat, do: [messages], else: [messages, schema]

      assert {:ok, %Response{usage: usage}} =
               apply(Adapter, operation, args ++ [opts(http_adapter, step: :test_step)])

      assert usage.cache_read_input_tokens == 4
      assert usage.cache_creation_input_tokens == 0
      assert usage.reasoning_tokens == 5
      assert is_number(usage.input_cost)
      assert is_number(usage.output_cost)
      assert is_number(usage.total_cost)

      start_event = [:mnemosyne, :llm, operation, :start]
      stop_event = [:mnemosyne, :llm, operation, :stop]

      assert_receive {:telemetry, ^start_event, _,
                      %{model: "openai:gpt-4o-mini", step: :test_step}}

      assert_receive {:telemetry, ^stop_event, measurements, metadata}
      assert metadata.step == :test_step
      if operation == :chat_structured, do: assert(metadata.schema == schema)
      assert measurements.tokens_input == 10
      assert measurements.tokens_output == 20
      assert is_integer(measurements.duration)
    end
  end

  test "parses Zoi schemas without requiring callers to enable key coercion" do
    http_adapter = fn req ->
      {req, Req.Response.new(status: 200, body: completion(~s({"person":{"name":"Alice"}})))}
    end

    schema = Zoi.map(%{person: Zoi.map(%{name: Zoi.string()})})

    assert {:ok, %Response{content: %{person: %{name: "Alice"}}}} =
             Adapter.chat_structured(
               [%{role: :user, content: "Extract Alice"}],
               schema,
               opts(http_adapter)
             )
  end

  test "preserves zero usage and costs" do
    http_adapter = fn req ->
      body =
        completion("Hello")
        |> Map.put("usage", %{"input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0})

      {req, Req.Response.new(status: 200, body: body)}
    end

    assert {:ok, %Response{usage: usage}} =
             Adapter.chat([%{role: :user, content: "Hi"}], opts(http_adapter))

    assert usage.input_tokens == 0
    assert usage.output_tokens == 0
    assert usage.cache_read_input_tokens == 0
    assert usage.cache_creation_input_tokens == 0
    assert usage.total_cost == 0.0
    refute Enum.any?(usage, fn {_key, value} -> is_nil(value) end)
  end

  test "rejects structured content that does not satisfy the supplied schema" do
    http_adapter = fn req ->
      {req, Req.Response.new(status: 200, body: completion(~s({"name":42})))}
    end

    assert {:error, %AdapterError{operation: :chat_structured}} =
             Adapter.chat_structured(
               [%{role: :user, content: "Extract a name"}],
               Zoi.map(%{name: Zoi.string()}, coerce: true),
               opts(http_adapter)
             )
  end

  defp attach_telemetry do
    handler_id = {__MODULE__, self()}

    events =
      for operation <- [:chat, :chat_structured], event <- [:start, :stop] do
        [:mnemosyne, :llm, operation, event]
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
        model: "openai:gpt-4o-mini",
        api_key: "test-key",
        req_http_options: [adapter: __MODULE__, retry: false]
      ],
      extra
    )
  end

  defp completion(content) do
    %{
      "id" => "resp-test",
      "object" => "response",
      "created_at" => 1_700_000_000,
      "model" => "gpt-4o-mini",
      "status" => "completed",
      "output" => [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => content}]
        }
      ],
      "usage" => %{"input_tokens" => 10, "output_tokens" => 20, "total_tokens" => 30}
    }
  end
end
