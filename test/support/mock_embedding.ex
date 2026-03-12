defmodule Mnemosyne.MockEmbedding do
  @moduledoc false
  @behaviour Mnemosyne.Embedding

  alias Mnemosyne.Embedding.Response

  @impl true
  def embed(_text, _opts \\ []) do
    {:ok,
     %Response{
       vectors: [List.duplicate(0.1, 128)],
       model: "mock:embed",
       usage: %{input_tokens: 5}
     }}
  end

  @impl true
  def embed_batch(texts, _opts \\ []) do
    vectors = Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)

    {:ok,
     %Response{vectors: vectors, model: "mock:embed", usage: %{input_tokens: length(texts) * 5}}}
  end
end
