defmodule Mnemosyne.Pipeline.Prompts.ReasonProcedural do
  @moduledoc """
  Prompt for synthesizing retrieved procedural memory nodes
  into actionable instructions relevant to the query.

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
  def build_messages(%{query: query, nodes: nodes}) do
    formatted_nodes =
      nodes
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {node, i} ->
        timestamp = format_timestamp(node.created_at)
        score = format_return_score(node.return_score)

        "Procedure #{i} [#{timestamp}] (return: #{score}): WHEN #{node.condition} DO #{node.instruction} EXPECT #{node.expected_outcome}"
      end)

    [
      %{
        role: :system,
        content: """
        You are an expert at synthesizing procedural knowledge into actionable guidance.
        Given a query and a set of known procedures, analyze them and produce a synthesis.

        Timestamps reflect when knowledge was extracted, not when the original event occurred.
        Return scores indicate how successful each procedure was (0.0 = failed, 1.0 = succeeded).
        Distinguish proven procedures (high return) from failed ones (low return).
        Identify redundant procedures and keep the most successful version.

        Return a JSON object with:
        - "reasoning": your analysis of which procedures apply and their track record
        - "information": the synthesized guidance, concise (3-5 sentences)\
        """
      },
      %{
        role: :user,
        content: """
        Query: #{query}

        Known Procedures:
        #{formatted_nodes}

        Synthesis:\
        """
      }
    ]
  end

  @impl true
  def parse_response(%{information: information}) when is_binary(information) do
    case String.trim(information) do
      "" -> {:error, PromptError.exception(prompt: :reason_procedural, reason: :empty_response)}
      summary -> {:ok, summary}
    end
  end

  def parse_response(_) do
    {:error, PromptError.exception(prompt: :reason_procedural, reason: :empty_response)}
  end

  defp format_return_score(nil), do: "N/A"

  defp format_return_score(score) when is_float(score),
    do: :erlang.float_to_binary(score, decimals: 2)

  defp format_return_score(score), do: "#{score}"

  defp format_timestamp(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_timestamp(_), do: "unknown"
end
