defmodule Mnemosyne.Pipeline.Prompts.MergeSemantic do
  @moduledoc """
  Prompt for deciding whether two similar semantic memories should be
  merged, and synthesizing the merged statement when they should.

  Follows the PlugMem update operation: the LLM classifies the pair into
  one of three relationships and produces a merged statement. Pairs that
  are only weakly related are kept separate to avoid stitching unrelated
  facts together.

  Returns structured output via `chat_structured/3` using a Zoi schema.
  """

  alias Mnemosyne.Errors.Invalid.PromptError

  @relationships %{
    "UPDATE_SAME_FACT" => :merge,
    "SAME_TOPIC_MERGE_WELL" => :merge,
    "WEAK_RELATED_STITCH_RISK" => :keep_both
  }

  @doc "Returns the Zoi schema for structured LLM output validation."
  @spec schema :: Zoi.Type.t()
  def schema do
    Zoi.map(
      %{
        merged_statement: Zoi.string(),
        relationship: Zoi.string()
      },
      coerce: true
    )
  end

  @doc "Builds the system and user messages for the semantic merge prompt."
  @spec build_messages(map()) :: [map()]
  def build_messages(%{earlier: earlier, later: later} = variables) do
    overlay = if variables[:overlay], do: "\n\n#{variables.overlay}", else: ""

    [
      %{
        role: :system,
        content:
          """
          You are given two memory items about a related topic. One came earlier
          (Information 1) and the other came later (Information 2).

          Your tasks:
          1. Merge them into ONE improved, clear, concise statement. Do not invent new facts.
          2. Classify the relationship between the two items (choose exactly ONE):

          "UPDATE_SAME_FACT"
          - Information 1 and 2 describe the same fact or event, and Information 2
            mainly updates, corrects, or refines details of Information 1.
          - The merged statement fully supersedes both originals.

          "SAME_TOPIC_MERGE_WELL"
          - Information 1 and 2 are strongly related under the same topic, and the
            merged statement reads naturally as a unified summary (not an awkward splice).

          "WEAK_RELATED_STITCH_RISK"
          - Information 1 and 2 are only weakly related; merging feels like stitching
            two segments, and removing either original would likely harm future retrieval.

          If the two memories conflict, prefer Information 2 as the more up-to-date.

          Return a JSON object with:
          - "merged_statement": the merged statement (string)
          - "relationship": one of the three labels above\
          """ <> overlay
      },
      %{
        role: :user,
        content: """
        Information 1 (Earlier Information): #{earlier}

        Information 2 (Later Information): #{later}\
        """
      }
    ]
  end

  @doc "Parses the merge decision from the LLM response."
  @spec parse_response(map()) ::
          {:ok, {:merge, String.t()} | :keep_both} | {:error, PromptError.t()}
  def parse_response(%{merged_statement: statement, relationship: relationship})
      when is_binary(statement) and is_binary(relationship) do
    case Map.get(@relationships, String.trim(relationship)) do
      :merge when statement != "" -> {:ok, {:merge, statement}}
      :keep_both -> {:ok, :keep_both}
      _ -> {:error, PromptError.exception(prompt: :merge_semantic, reason: :invalid_relationship)}
    end
  end

  def parse_response(_) do
    {:error, PromptError.exception(prompt: :merge_semantic, reason: :invalid_decision)}
  end
end
