defmodule Mnemosyne.Pipeline.Prompts.GetRefinedQuery do
  @moduledoc """
  Prompt for refining retrieval tags during multi-hop retrieval.
  Generates bridge-concept search tags targeting information not yet reached.
  """

  @behaviour Mnemosyne.Prompt

  alias Mnemosyne.Errors.Invalid.PromptError

  @spec schema :: Zoi.Type.t()
  def schema do
    Zoi.map(%{tags: Zoi.list(Zoi.string())}, coerce: true)
  end

  @impl true
  def build_messages(
        %{original_query: query, mode: mode, retrieved_so_far: candidates} = variables
      ) do
    overlay = if variables[:overlay], do: "\n\n#{variables.overlay}", else: ""

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
        content:
          """
          You are a search refinement expert. A multi-hop retrieval is in progress for a #{mode} memory query.
          Based on the original query and what each hop has found so far, generate refined search tags
          that target information the current results haven't reached yet.

          Focus on bridge concepts: entities or ideas that connect what's been found to what the query still needs.

          Return a JSON object with a "tags" array of 3-5 concise search terms.
          Return an empty array if the current results are adequate.\
          """ <> overlay
      },
      %{
        role: :user,
        content: """
        Original query: #{query}

        Retrieved so far (by hop):
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
