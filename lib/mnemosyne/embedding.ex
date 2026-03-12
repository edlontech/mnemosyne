defmodule Mnemosyne.Embedding do
  @moduledoc """
  Behaviour for text embedding generation.

  Implementations must convert text into vector representations
  suitable for similarity search.
  """

  @callback embed(text :: String.t()) :: {:ok, [float()]} | {:error, term()}
  @callback embed_batch(texts :: [String.t()]) :: {:ok, [[float()]]} | {:error, term()}
end
