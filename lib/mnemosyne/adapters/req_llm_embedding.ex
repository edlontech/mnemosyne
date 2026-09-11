if Code.ensure_loaded?(ReqLLM) do
  defmodule Mnemosyne.Adapters.ReqLLMEmbedding do
    @moduledoc """
    Embedding adapter backed by the optional ReqLLM dependency.

    Translates `Mnemosyne.Embedding` calls to ReqLLM's `embed/3` API,
    preserving input order for batches. Requires a `:model` option such as
    `"openai:text-embedding-3-small"`; the response reports this requested model
    because ReqLLM does not return a model identifier with embeddings.

    Options such as `:dimensions`, `:api_key`, and `:provider_options` are
    forwarded to ReqLLM. Float encoding and usage reporting are always enabled
    to satisfy Mnemosyne's vector and telemetry contracts.
    """
    @behaviour Mnemosyne.Embedding

    alias Mnemosyne.Embedding.Response
    alias Mnemosyne.Errors.Framework.AdapterError

    @impl true
    def embed(text, opts) do
      model = Keyword.fetch!(opts, :model)

      Mnemosyne.Telemetry.span(
        [:embedding, :embed],
        %{model: model, text_length: String.length(text)},
        fn -> {do_embed([text], opts, :embed), %{}} end
      )
    end

    @impl true
    def embed_batch(texts, opts) do
      model = Keyword.fetch!(opts, :model)

      Mnemosyne.Telemetry.span([:embedding, :embed_batch], %{model: model}, fn ->
        result = do_embed(texts, opts, :embed_batch)

        measurements =
          case result do
            {:ok, _} -> %{batch_size: length(texts)}
            {:error, _} -> %{}
          end

        {result, measurements}
      end)
    end

    defp do_embed(texts, opts, operation) do
      {model, req_opts} = Keyword.pop!(opts, :model)
      req_opts = Keyword.merge(req_opts, return_usage: true, encoding_format: "float")

      case ReqLLM.embed(model, texts, req_opts) do
        {:ok, %{embedding: vectors, usage: usage}} ->
          {:ok, %Response{vectors: vectors, model: model, usage: extract_usage(usage)}}

        {:error, reason} ->
          {:error,
           AdapterError.exception(adapter: __MODULE__, operation: operation, reason: reason)}
      end
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
