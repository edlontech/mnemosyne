defmodule Mnemosyne.Pipeline.Prompts.GetMode do
  @moduledoc """
  Prompt for classifying a query into a memory retrieval mode:
  `:episodic`, `:semantic`, `:procedural`, or `:mixed`.
  """

  @behaviour Mnemosyne.Prompt

  alias Mnemosyne.Errors.Invalid.PromptError

  @mode_map %{
    "episodic" => :episodic,
    "semantic" => :semantic,
    "procedural" => :procedural,
    "mixed" => :mixed
  }

  @impl true
  def build_messages(%{query: query} = variables) do
    overlay = if variables[:overlay], do: "\n\n#{variables.overlay}", else: ""

    [
      %{
        role: :system,
        content:
          """
          You are an expert at classifying memory retrieval queries.
          Given a query, determine which type of memory is most relevant:

          - episodic: Questions about past experiences, events, or "what happened when..."
          - semantic: Questions about facts, concepts, or general knowledge
          - procedural: Questions about how to do something, instructions, or procedures
          - mixed: Questions that require multiple memory types to answer fully

          Respond with ONLY one word: episodic, semantic, procedural, or mixed.\
          """ <> overlay
      },
      %{
        role: :user,
        content: "Query: #{query}"
      }
    ]
  end

  @impl true
  def parse_response(response) do
    key = response |> String.trim() |> String.downcase()

    case Map.get(@mode_map, key) do
      nil -> {:error, PromptError.exception(prompt: :get_mode, reason: :invalid_mode)}
      mode -> {:ok, mode}
    end
  end
end
