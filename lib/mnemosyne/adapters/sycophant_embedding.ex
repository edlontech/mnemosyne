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

    @impl true
    def embed(text, opts) do
      do_embed([text], opts)
    end

    @impl true
    def embed_batch(texts, opts) do
      do_embed(texts, opts)
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
    defp extract_usage(usage), do: %{input_tokens: usage.input_tokens}
  end
end
