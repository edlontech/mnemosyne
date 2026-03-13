defmodule Mnemosyne.Prompt do
  @moduledoc """
  Behaviour for building LLM prompts and parsing responses.

  Implementations construct message lists from template variables
  and extract structured data from raw LLM output.
  """

  @callback build_messages(variables :: map()) :: [%{role: atom(), content: String.t()}]
  @callback parse_response(response :: String.t()) ::
              {:ok, term()} | {:error, Mnemosyne.Errors.Invalid.PromptError.t()}
end
