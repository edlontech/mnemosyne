defmodule Mnemosyne.Pipeline.Prompts.ReasonSemantic do
  @moduledoc """
  Prompt for synthesizing retrieved semantic memory nodes
  into a factual summary relevant to the query.

  Uses structured LLM output via `chat_structured/3` with a Zoi schema.
  """

  @behaviour Mnemosyne.Prompt

  alias Mnemosyne.Errors.Invalid.PromptError

  @spec schema :: Zoi.Type.t()
  def schema do
    Zoi.map(
      %{
        reasoning: Zoi.string(),
        information: Zoi.string()
      },
      coerce: true
    )
  end

  @impl true
  def build_messages(%{query: query, nodes: nodes} = variables) do
    overlay = if variables[:overlay], do: "\n\n#{variables.overlay}", else: ""

    formatted_nodes =
      nodes
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {node, i} ->
        timestamp = format_timestamp(node.created_at)
        "Fact #{i} [#{timestamp}] (confidence: #{node.confidence}): #{node.proposition}"
      end)

    [
      %{
        role: :system,
        content:
          """
          You are an expert at synthesizing factual knowledge into coherent summaries.
          Given a query and a set of known facts, extract all the information that is
          useful for the query. Use the original wording of the facts as much as possible:
          do not replace names, numbers, dates or terms with synonyms or paraphrases.

          Timestamps show when the experience happened if that was recorded, otherwise when it was stored.
          Prioritize higher-confidence facts. When facts contradict each other, prefer the
          most recent or highest-confidence version.
          If none of the facts is relevant to the query, say so in one sentence.

          Return a JSON object with:
          - "reasoning": your analysis of which facts are relevant and how they relate
          - "information": all the useful information you extracted, with nothing
            relevant left out\
          """ <> overlay
      },
      %{
        role: :user,
        content: """
        Current Date: #{Calendar.strftime(variables[:now] || DateTime.utc_now(), "%Y-%m-%d")}

        Query: #{query}

        Known Facts:
        #{formatted_nodes}

        Synthesis:\
        """
      }
    ]
  end

  @impl true
  def parse_response(%{information: information}) when is_binary(information) do
    case String.trim(information) do
      "" -> {:error, PromptError.exception(prompt: :reason_semantic, reason: :empty_response)}
      summary -> {:ok, summary}
    end
  end

  def parse_response(_) do
    {:error, PromptError.exception(prompt: :reason_semantic, reason: :empty_response)}
  end

  defp format_timestamp(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_timestamp(_), do: "unknown"
end
