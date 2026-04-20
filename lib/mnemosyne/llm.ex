defmodule Mnemosyne.LLM do
  @moduledoc """
  Behaviour for LLM chat completions.

  Implementations must provide `chat/2` and `chat_structured/3` callbacks
  that take messages and options, returning a Response struct.
  """
  @type message :: %{role: atom(), content: String.t()}

  defmodule Response do
    @moduledoc "Struct returned by LLM chat completions."

    @enforce_keys [:content]
    defstruct [:content, :model, usage: %{}]

    @type t :: %__MODULE__{
            content: term(),
            model: String.t(),
            usage: map()
          }
  end

  @callback chat(messages :: [message()], opts :: keyword()) ::
              {:ok, Response.t()} | {:error, Mnemosyne.Errors.Framework.AdapterError.t()}
  @callback chat_structured(messages :: [message()], schema :: term(), opts :: keyword()) ::
              {:ok, Response.t()} | {:error, Mnemosyne.Errors.Framework.AdapterError.t()}
end
