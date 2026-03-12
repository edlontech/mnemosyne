defmodule Mnemosyne.LLM do
  @moduledoc """
  Behaviour for LLM chat completions.

  Implementations must provide a `chat/2` callback that takes a list
  of message maps and options, returning the model's text response.
  """

  @callback chat(messages :: [%{role: atom(), content: String.t()}], opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}
end
