defmodule Mnemosyne.LLM do
  @moduledoc """
  Behaviour for LLM chat completions.

  Implementations must provide `chat/2` and `chat_structured/3` callbacks
  that take messages and options, returning a Response struct.
  """
  use TypedStruct

  @type message :: %{role: atom(), content: String.t()}

  defmodule Response do
    @moduledoc "Struct returned by LLM chat completions."
    use TypedStruct

    typedstruct do
      field :content, term(), enforce: true
      field :model, String.t()
      field :usage, map(), default: %{}
    end
  end

  @callback chat(messages :: [message()], opts :: keyword()) ::
              {:ok, Response.t()} | {:error, term()}
  @callback chat_structured(messages :: [message()], schema :: term(), opts :: keyword()) ::
              {:ok, Response.t()} | {:error, term()}
end
