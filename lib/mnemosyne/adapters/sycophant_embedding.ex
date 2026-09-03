if Code.ensure_loaded?(Sycophant) do
  defmodule Mnemosyne.Adapters.SycophantEmbedding do
    @moduledoc """
    Embedding adapter backed by Sycophant.

    Translates between the `Mnemosyne.Embedding` behaviour and Sycophant's
    `embed/2` API.
    """
    @behaviour Mnemosyne.Embedding

    alias Mnemosyne.Embedding.Response
    alias Sycophant.EmbeddingRequest

    @sycophant_usage_keys [
      :input_tokens,
      :output_tokens,
      :cache_creation_input_tokens,
      :cache_read_input_tokens,
      :reasoning_tokens,
      :input_cost,
      :output_cost,
      :cache_read_cost,
      :cache_write_cost,
      :reasoning_cost,
      :total_cost
    ]

    @impl true
    def embed(text, opts) do
      {model, _rest} = Keyword.pop!(opts, :model)

      Mnemosyne.Telemetry.span(
        [:embedding, :embed],
        %{model: model, text_length: String.length(text)},
        fn ->
          result = do_embed([text], opts)
          {result, %{}}
        end
      )
    end

    @impl true
    def embed_batch(texts, opts) do
      {model, _rest} = Keyword.pop!(opts, :model)

      Mnemosyne.Telemetry.span([:embedding, :embed_batch], %{model: model}, fn ->
        result = do_embed(texts, opts)

        extra =
          case result do
            {:ok, _} -> %{batch_size: length(texts)}
            _ -> %{}
          end

        {result, extra}
      end)
    end

    defp do_embed(inputs, opts) do
      {model, rest} = Keyword.pop!(opts, :model)

      request = %EmbeddingRequest{
        inputs: inputs,
        model: model,
        params: build_params(rest)
      }

      case Sycophant.embed(request, []) do
        {:ok, response} ->
          vectors = Map.get(response.embeddings, :float, [])
          usage = extract_usage(response.usage)
          {:ok, %Response{vectors: vectors, model: response.model, usage: usage}}

        {:error, _} = err ->
          err
      end
    end

    defp build_params(opts) do
      case Keyword.get(opts, :dimensions) do
        nil -> nil
        dim -> %Sycophant.EmbeddingParams{dimensions: dim}
      end
    end

    defp extract_usage(nil), do: %{}

    defp extract_usage(usage) do
      usage
      |> Map.from_struct()
      |> Map.take(@sycophant_usage_keys)
      |> Map.put(:currency, get_in(usage, [Access.key(:pricing), Access.key(:currency)]))
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
    end
  end
end
