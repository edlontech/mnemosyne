defmodule Mnemosyne.LLM do
  @moduledoc """
  Behaviour for LLM chat completions.

  Implementations must provide `chat/2` and `chat_structured/3` callbacks
  that take messages and options, returning a Response struct.
  """
  @type message :: %{role: atom(), content: String.t()}

  defmodule Response do
    @moduledoc "Struct returned by LLM chat completions."

    @typedoc """
    Optional provider-reported usage data.

    Recognized keys are `:input_tokens`, `:output_tokens`,
    `:cache_creation_input_tokens`, `:cache_read_input_tokens`,
    `:reasoning_tokens`, `:input_cost`, `:output_cost`, `:cache_read_cost`,
    `:cache_write_cost`, `:reasoning_cost`, `:total_cost`, and `:currency`.
    All keys are optional; adapters may include additional keys.
    """
    @type usage :: map()

    @enforce_keys [:content]
    defstruct [:content, :model, usage: %{}]

    @type t :: %__MODULE__{
            content: term(),
            model: String.t(),
            usage: usage()
          }
  end

  @callback chat(messages :: [message()], opts :: keyword()) ::
              {:ok, Response.t()} | {:error, Mnemosyne.Errors.Framework.AdapterError.t()}
  @callback chat_structured(messages :: [message()], schema :: term(), opts :: keyword()) ::
              {:ok, Response.t()} | {:error, Mnemosyne.Errors.Framework.AdapterError.t()}
end
