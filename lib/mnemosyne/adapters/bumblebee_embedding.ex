if Code.ensure_loaded?(Bumblebee) do
  defmodule Mnemosyne.Adapters.BumblebeeEmbedding do
    @moduledoc """
    Embedding adapter backed by Bumblebee's `Nx.Serving`.

    Expects a pre-built serving (struct or registered process name) passed
    via the `:serving` option. The serving must implement the text embedding
    interface (e.g. created via `Bumblebee.Text.text_embedding/3`).

    ## Options

      * `:serving` - (required) an `Nx.Serving` struct or registered process name
      * `:model` - (optional) model name string for observability
    """
    @behaviour Mnemosyne.Embedding

    alias Mnemosyne.Embedding.Response

    @impl true
    def embed(text, opts) do
      {_serving, rest} = Keyword.pop!(opts, :serving)
      model = Keyword.get(rest, :model)

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
      {_serving, rest} = Keyword.pop!(opts, :serving)
      model = Keyword.get(rest, :model)

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

    defp do_embed(texts, opts) do
      {serving, rest} = Keyword.pop!(opts, :serving)
      model = Keyword.get(rest, :model)

      results = run_serving(serving, texts)
      vectors = Enum.map(results, fn %{embedding: t} -> Nx.to_flat_list(t) end)

      {:ok, %Response{vectors: vectors, model: model, usage: %{}}}
    rescue
      e -> {:error, e}
    end

    defp run_serving(serving, texts) when is_struct(serving, Nx.Serving) do
      Nx.Serving.run(serving, texts)
    end

    defp run_serving(name, texts) when is_atom(name) or is_pid(name) do
      Nx.Serving.batched_run(name, texts)
    end
  end
end
