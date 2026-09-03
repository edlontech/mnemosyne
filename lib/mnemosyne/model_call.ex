defmodule Mnemosyne.ModelCall.Context do
  @moduledoc "Trusted repository attribution for a model call."

  @enforce_keys [:repo_id, :operation]
  defstruct [:repo_id, :operation, :source_id, labels: %{}]

  @type scalar_label :: String.t() | atom() | number() | boolean()

  @type t :: %__MODULE__{
          repo_id: String.t(),
          operation: atom(),
          source_id: String.t() | nil,
          labels: %{optional(String.t() | atom()) => scalar_label()}
        }
end

defmodule Mnemosyne.ModelCall do
  @moduledoc "Emits repository-attributed telemetry around model adapter calls."

  alias Mnemosyne.Embedding
  alias Mnemosyne.LLM
  alias Mnemosyne.ModelCall.Context
  alias Mnemosyne.Telemetry

  @token_keys [
    :input_tokens,
    :output_tokens,
    :cache_creation_input_tokens,
    :cache_read_input_tokens,
    :reasoning_tokens
  ]
  @cost_keys [
    :input_cost,
    :output_cost,
    :cache_read_cost,
    :cache_write_cost,
    :reasoning_cost,
    :total_cost
  ]

  @spec chat(Context.t() | nil, module(), atom(), [LLM.message()], keyword()) ::
          {:ok, LLM.Response.t()} | {:error, term()}
  def chat(context, adapter, step, messages, opts),
    do: invoke(context, :llm, :chat, adapter, step, opts, fn -> adapter.chat(messages, opts) end)

  @spec chat_structured(Context.t() | nil, module(), atom(), [LLM.message()], term(), keyword()) ::
          {:ok, LLM.Response.t()} | {:error, term()}
  def chat_structured(context, adapter, step, messages, schema, opts),
    do:
      invoke(context, :llm, :chat_structured, adapter, step, opts, fn ->
        adapter.chat_structured(messages, schema, opts)
      end)

  @spec embed(Context.t() | nil, module(), atom(), String.t(), keyword()) ::
          {:ok, Embedding.Response.t()} | {:error, term()}
  def embed(context, adapter, step, text, opts),
    do:
      invoke(context, :embedding, :embed, adapter, step, opts, fn -> adapter.embed(text, opts) end)

  @spec embed_batch(Context.t() | nil, module(), atom(), [String.t()], keyword()) ::
          {:ok, Embedding.Response.t()} | {:error, term()}
  def embed_batch(context, adapter, step, texts, opts),
    do:
      invoke(context, :embedding, :embed_batch, adapter, step, opts, fn ->
        adapter.embed_batch(texts, opts)
      end)

  defp invoke(nil, _kind, _callback, _adapter, _step, _opts, fun), do: fun.()

  defp invoke(%Context{} = context, kind, callback, adapter, step, opts, fun) do
    metadata = %{
      repo_id: context.repo_id,
      labels: context.labels,
      operation: context.operation,
      source_id: context.source_id,
      kind: kind,
      callback: callback,
      adapter: adapter,
      step: step,
      requested_model: Keyword.get(opts, :model)
    }

    Telemetry.span([:model, :call], metadata, fn ->
      result = fun.()
      {measurements, terminal_metadata} = terminal_fields(result, metadata.requested_model)
      {result, measurements, terminal_metadata}
    end)
  end

  defp terminal_fields({:ok, response}, requested_model) when is_map(response) do
    usage = Map.get(response, :usage)
    response_model = Map.get(response, :model) || requested_model

    metadata = %{status: :ok, response_model: response_model}

    metadata =
      case usage do
        %{currency: currency} when is_binary(currency) -> Map.put(metadata, :currency, currency)
        _ -> metadata
      end

    {usage_measurements(usage), metadata}
  end

  defp terminal_fields({:error, _reason}, requested_model) do
    {%{}, %{status: :error, response_model: requested_model}}
  end

  defp terminal_fields(_result, requested_model) do
    {%{}, %{status: :ok, response_model: requested_model}}
  end

  defp usage_measurements(usage) when is_map(usage) do
    usage
    |> Map.take(@token_keys ++ @cost_keys)
    |> Map.filter(&valid_measurement?/1)
  end

  defp usage_measurements(_usage), do: %{}

  defp valid_measurement?({key, value}) when key in @token_keys,
    do: is_integer(value) and value >= 0

  defp valid_measurement?({key, value}) when key in @cost_keys, do: is_number(value)
end
