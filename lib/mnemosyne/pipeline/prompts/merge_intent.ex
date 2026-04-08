defmodule Mnemosyne.Pipeline.Prompts.MergeIntent do
  @moduledoc """
  Prompt for merging two similar intent descriptions into a single
  unified intent that captures the essence of both.

  Returns structured output via `chat_structured/3` using a Zoi schema.
  """

  @behaviour Mnemosyne.Prompt

  alias Mnemosyne.Errors.Invalid.PromptError

  @doc "Returns the Zoi schema for structured LLM output validation."
  @spec schema :: Zoi.Type.t()
  def schema do
    Zoi.map(
      %{merged_intent: Zoi.string()},
      coerce: true
    )
  end

  @impl true
  def build_messages(%{existing_intent: existing, new_intent: new} = variables) do
    overlay = if variables[:overlay], do: "\n\n#{variables.overlay}", else: ""

    [
      %{
        role: :system,
        content:
          """
          You are an expert at consolidating goals and intents.
          Given two similar intent descriptions, merge them into a single concise intent
          that captures the meaning of both without losing important nuance.

          Return your response as a JSON object with a "merged_intent" field containing
          the unified intent description as a single string.\
          """ <> overlay
      },
      %{
        role: :user,
        content: """
        Existing intent: #{existing}

        New intent: #{new}

        Merged intent:\
        """
      }
    ]
  end

  @impl true
  def parse_response(%{merged_intent: intent}) when is_binary(intent) do
    trimmed = String.trim(intent)

    if trimmed == "" do
      {:error, PromptError.exception(prompt: :merge_intent, reason: :invalid_merge_result)}
    else
      {:ok, trimmed}
    end
  end

  def parse_response(_) do
    {:error, PromptError.exception(prompt: :merge_intent, reason: :invalid_merge_result)}
  end
end
