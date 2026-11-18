defmodule Mnemosyne.Pipeline.Prompts.GetPlan do
  @moduledoc """
  Prompt that plans a retrieval in one call: classifies the query into a
  memory mode (`:episodic`, `:semantic`, `:procedural` or `:mixed`) and
  generates the search tags used to query the knowledge graph.

  Returns structured output via `chat_structured/3` using a Zoi schema.
  """

  alias Mnemosyne.Errors.Invalid.PromptError

  @mode_map %{
    "episodic" => :episodic,
    "semantic" => :semantic,
    "procedural" => :procedural,
    "mixed" => :mixed
  }

  @doc "Returns the Zoi schema for structured LLM output validation."
  @spec schema :: Zoi.Type.t()
  def schema do
    Zoi.map(
      %{mode: Zoi.enum(Map.keys(@mode_map)), tags: Zoi.list(Zoi.string())},
      coerce: true
    )
  end

  @doc "Builds the system and user messages for the retrieval planning prompt."
  @spec build_messages(map()) :: [map()]
  def build_messages(%{query: query} = variables) do
    overlay = if variables[:overlay], do: "\n\n#{variables.overlay}", else: ""

    [
      %{
        role: :system,
        content:
          """
          You are an expert at planning memory retrieval strategies.
          Given a query, first classify which type of memory is most relevant, then
          generate a prioritized list of search tags that would help find relevant
          memories in a knowledge graph.

          Memory modes:
          - episodic: Questions about past experiences, events, or "what happened when..."
          - semantic: Questions about facts, concepts, or general knowledge
          - procedural: Questions about how to do something, instructions, or procedures
          - mixed: Questions that require multiple memory types to answer fully

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

          Return a JSON object with:
          - "mode": one of "episodic", "semantic", "procedural", "mixed"
          - "tags": the list of search tags\
          """ <> overlay
      },
      %{
        role: :user,
        content: """
        Query: #{query}

        Plan the retrieval:\
        """
      }
    ]
  end

  @doc "Validates the planned mode and tags, returning the mode as an atom."
  @spec parse_response(map()) ::
          {:ok, %{mode: atom(), tags: [String.t()]}} | {:error, PromptError.t()}
  def parse_response(%{mode: mode, tags: tags}) when is_binary(mode) and is_list(tags) do
    tags = tags |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    case {Map.get(@mode_map, mode |> String.trim() |> String.downcase()), tags} do
      {nil, _tags} ->
        {:error, PromptError.exception(prompt: :get_plan, reason: :invalid_mode)}

      {_mode, []} ->
        {:error, PromptError.exception(prompt: :get_plan, reason: :no_tags_generated)}

      {mode, tags} ->
        {:ok, %{mode: mode, tags: tags}}
    end
  end

  def parse_response(_),
    do: {:error, PromptError.exception(prompt: :get_plan, reason: :invalid_plan)}
end
