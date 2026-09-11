if Code.ensure_loaded?(ReqLLM) do
  defmodule Mnemosyne.Adapters.ReqLLM do
    @moduledoc """
    LLM adapter backed by the optional ReqLLM dependency.

    Translates `Mnemosyne.LLM` calls to ReqLLM's `generate_text/3` and
    `generate_object/4` APIs. Structured output is parsed through the supplied
    Zoi schema to preserve the key types expected by Mnemosyne's prompts.

    Requires a `:model` option in ReqLLM's `"provider:model"` format. The optional
    `:step` is used for telemetry; remaining options are forwarded to ReqLLM.
    Usage and costs are preserved, with cache token aliases added for Mnemosyne.
    """
    @behaviour Mnemosyne.LLM

    alias Mnemosyne.Errors.Framework.AdapterError
    alias Mnemosyne.LLM.Response

    @impl true
    def chat(messages, opts) do
      {model, req_opts} = Keyword.pop!(opts, :model)
      {step, req_opts} = Keyword.pop(req_opts, :step)

      Mnemosyne.Telemetry.span([:llm, :chat], %{model: model, step: step}, fn ->
        case ReqLLM.generate_text(model, messages, req_opts) do
          {:ok, response} ->
            success(response, ReqLLM.Response.text(response))

          {:error, reason} ->
            failure(reason, :chat)
        end
      end)
    end

    @impl true
    def chat_structured(messages, schema, opts) do
      {model, req_opts} = Keyword.pop!(opts, :model)
      {step, req_opts} = Keyword.pop(req_opts, :step)

      Mnemosyne.Telemetry.span(
        [:llm, :chat_structured],
        %{model: model, step: step, schema: schema},
        fn ->
          with {:ok, response} <- ReqLLM.generate_object(model, messages, schema, req_opts),
               {:ok, content} <- parse_object(schema, ReqLLM.Response.object(response)) do
            success(response, content)
          else
            {:error, reason} ->
              failure(reason, :chat_structured)
          end
        end
      )
    end

    defp parse_object(schema, object) do
      schema
      |> Zoi.Schema.traverse(fn
        %Zoi.Types.Map{} = map -> Zoi.coerce(map)
        type -> type
      end)
      |> Zoi.coerce()
      |> Zoi.parse(object)
    end

    defp success(response, content) do
      usage = extract_usage(response.usage)
      result = %Response{content: content, model: response.model, usage: usage}

      {{:ok, result}, %{tokens_input: usage[:input_tokens], tokens_output: usage[:output_tokens]}}
    end

    defp failure(reason, operation) do
      {{:error,
        AdapterError.exception(adapter: __MODULE__, operation: operation, reason: reason)}, %{}}
    end

    defp extract_usage(nil), do: %{}

    defp extract_usage(usage) do
      usage
      |> Map.put(:cache_read_input_tokens, usage[:cached_tokens])
      |> Map.put(:cache_creation_input_tokens, usage[:cache_creation_tokens])
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
    end
  end
end
