defmodule Mnemosyne.Embedding do
  @moduledoc """
  Behaviour for text embedding generation.

  Implementations must convert text into vector representations
  suitable for similarity search.
  """
  defmodule Response do
    @moduledoc "Struct returned by embedding generation calls."

    @typedoc """
    Optional provider-reported usage data.

    Recognized keys are `:input_tokens`, `:output_tokens`,
    `:cache_creation_input_tokens`, `:cache_read_input_tokens`,
    `:reasoning_tokens`, `:input_cost`, `:output_cost`, `:cache_read_cost`,
    `:cache_write_cost`, `:reasoning_cost`, `:total_cost`, and `:currency`.
    All keys are optional; adapters may include additional keys.
    """
    @type usage :: map()

    @enforce_keys [:vectors]
    defstruct [:vectors, :model, usage: %{}]

    @type t :: %__MODULE__{
            vectors: [[float()]],
            model: String.t(),
            usage: usage()
          }
  end

  @callback embed(text :: String.t(), opts :: keyword()) ::
              {:ok, Response.t()} | {:error, Mnemosyne.Errors.Framework.AdapterError.t()}
  @callback embed_batch(texts :: [String.t()], opts :: keyword()) ::
              {:ok, Response.t()} | {:error, Mnemosyne.Errors.Framework.AdapterError.t()}
end
