defmodule Mnemosyne.Embedding do
  @moduledoc """
  Behaviour for text embedding generation.

  Implementations must convert text into vector representations
  suitable for similarity search.
  """
  use TypedStruct

  defmodule Response do
    @moduledoc "Struct returned by embedding generation calls."
    use TypedStruct

    typedstruct do
      field :vectors, [[float()]], enforce: true
      field :model, String.t()
      field :usage, map(), default: %{}
    end
  end

  @callback embed(text :: String.t(), opts :: keyword()) ::
              {:ok, Response.t()} | {:error, Mnemosyne.Errors.Framework.AdapterError.t()}
  @callback embed_batch(texts :: [String.t()], opts :: keyword()) ::
              {:ok, Response.t()} | {:error, Mnemosyne.Errors.Framework.AdapterError.t()}
end
