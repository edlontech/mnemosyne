defmodule Mnemosyne.Embedding do
  @moduledoc """
  Behaviour for text embedding generation.

  Implementations must convert text into vector representations
  suitable for similarity search.
  """
  defmodule Response do
    @moduledoc "Struct returned by embedding generation calls."

    @enforce_keys [:vectors]
    defstruct [:vectors, :model, usage: %{}]

    @type t :: %__MODULE__{
            vectors: [[float()]],
            model: String.t(),
            usage: map()
          }
  end

  @callback embed(text :: String.t(), opts :: keyword()) ::
              {:ok, Response.t()} | {:error, Mnemosyne.Errors.Framework.AdapterError.t()}
  @callback embed_batch(texts :: [String.t()], opts :: keyword()) ::
              {:ok, Response.t()} | {:error, Mnemosyne.Errors.Framework.AdapterError.t()}
end
