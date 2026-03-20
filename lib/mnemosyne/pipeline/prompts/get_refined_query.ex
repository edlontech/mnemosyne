defmodule Mnemosyne.Pipeline.Prompts.GetRefinedQuery do
  @moduledoc """
  Prompt for refining retrieval tags based on initial results.
  Generates new search tags conditioned on what was found so far.
  """

  @behaviour Mnemosyne.Prompt

  alias Mnemosyne.Errors.Invalid.PromptError

  @spec schema :: Zoi.Type.t()
  def schema do
    Zoi.map(%{tags: Zoi.list(Zoi.string())}, coerce: true)
  end

  @impl true
  def build_messages(%{original_query: query, mode: mode, retrieved_so_far: candidates}) do
    formatted_candidates =
      candidates
      |> Enum.take(20)
      |> Enum.map_join("\n", fn c ->
        content = String.slice(c.content, 0, 200)
        "  [#{c.type}] #{content}"
      end)

    [
      %{
        role: :system,
        content: """
        You are a search refinement expert. The initial retrieval for a #{mode} memory query
        returned weak results. Based on the original query and what was found, generate
        improved search tags that might find more relevant results.

        Return a JSON object with a "tags" array of 3-5 concise search terms.
        Return an empty array if the current results are adequate.\
        """
      },
      %{
        role: :user,
        content: """
        Original query: #{query}

        Retrieved so far:
        #{formatted_candidates}

        Refined search tags:\
        """
      }
    ]
  end

  @impl true
  def parse_response(%{tags: tags}) when is_list(tags), do: {:ok, tags}

  def parse_response(_),
    do: {:error, PromptError.exception(prompt: :get_refined_query, reason: :invalid_tags)}
end
