defmodule Mnemosyne.Pipeline.Prompts.GetPlan do
  @moduledoc """
  Prompt for generating retrieval tags from a query and its classified mode.
  Produces a list of search tags used to query the knowledge graph.
  """

  @behaviour Mnemosyne.Prompt

  alias Mnemosyne.Errors.Invalid.PromptError

  @impl true
  def build_messages(%{query: query, mode: mode} = variables) do
    overlay = if variables[:overlay], do: "\n\n#{variables.overlay}", else: ""

    [
      %{
        role: :system,
        content:
          """
          You are an expert at planning memory retrieval strategies.
          Given a query and its classified memory mode, generate a prioritized list of
          search tags that would help find relevant memories in a knowledge graph.

          Goal-directed tag selection:
          - Only generate tags that are HIGHLY LIKELY to retrieve evidence needed to
            answer the query.
          - Prefer tags that identify: the target entities the query asks about (people,
            organizations, places, works, events), bridge entities likely required for
            multi-hop retrieval, and explicit constraints (dates, years, roles, titles,
            unique descriptors, numbers).
          - Avoid low-signal or generic tags unlikely to retrieve helpful evidence
            (e.g. "known for", "famous").

          Concrete, grounded tags:
          - The MAJORITY of tags MUST be short text spans copied VERBATIM from the query
            (exact substrings).
          - You MAY add a SMALL number of non-literal tags only if they are short,
            strongly implied, and clearly necessary (e.g. a canonical name expansion or
            a standard alias).
          - If a tag is a verb, use its base (lemma) form (e.g. "direct", not "directed").

          Forbidden tags:
          - Do NOT generate the tag "user".
          - Do NOT use meta-labels or type names such as "Name", "Person", "Year",
            "Date", "City", "Country", "Location", "Genre", "Category".

          Keep the total number of tags proportionate to the query (not "as many as
          possible"), sorted by expected retrieval usefulness (most useful first).
          Respond with one tag per line. No numbering or bullet points.\
          """ <> overlay
      },
      %{
        role: :user,
        content: """
        Query: #{query}
        Memory Mode: #{mode}

        Generate retrieval tags:\
        """
      }
    ]
  end

  @impl true
  def parse_response(response) do
    tags =
      response
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case tags do
      [] -> {:error, PromptError.exception(prompt: :get_plan, reason: :no_tags_generated)}
      tags -> {:ok, tags}
    end
  end
end
