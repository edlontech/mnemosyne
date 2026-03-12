defmodule Mnemosyne.MockEmbedding do
  @moduledoc false
  @behaviour Mnemosyne.Embedding

  @impl true
  def embed(_text) do
    {:ok, List.duplicate(0.1, 128)}
  end

  @impl true
  def embed_batch(texts) do
    {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)}
  end
end
