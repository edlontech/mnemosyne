defmodule Mnemosyne.Errors.Invalid.PromptError do
  @moduledoc """
  Raised when an LLM prompt response cannot be parsed into the expected format.
  """
  use Splode.Error, fields: [:prompt, :reason], class: :invalid

  @type t :: %__MODULE__{}

  def message(%{prompt: prompt, reason: reason}) do
    "prompt parse error in #{prompt}: #{format_reason(reason)}"
  end

  defp format_reason(:empty_response), do: "LLM returned an empty response"
  defp format_reason(:no_facts_extracted), do: "no facts could be extracted"
  defp format_reason(:no_instructions_extracted), do: "no instructions could be extracted"
  defp format_reason(:no_tags_generated), do: "no tags could be generated"
  defp format_reason(:invalid_float), do: "expected a numeric value but got unparseable input"
  defp format_reason(:invalid_mode), do: "response did not match any known retrieval mode"
  defp format_reason(reason), do: inspect(reason)
end
