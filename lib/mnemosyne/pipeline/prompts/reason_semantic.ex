defmodule Mnemosyne.Pipeline.Prompts.ReasonSemantic do
  @moduledoc """
  Prompt for synthesizing retrieved semantic memory nodes
  into a factual summary relevant to the query.
  """

  @behaviour Mnemosyne.Prompt

  @impl true
  def build_messages(%{query: query, nodes: nodes}) do
    formatted_nodes =
      nodes
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {node, i} ->
        "Fact #{i} (confidence: #{node.confidence}): #{node.proposition}"
      end)

    [
      %{
        role: :system,
        content: """
        You are an expert at synthesizing factual knowledge into coherent summaries.
        Given a query and a set of known facts, produce a concise summary that
        addresses the query using the most relevant and high-confidence facts.

        Prioritize higher-confidence facts. Resolve contradictions by noting them.
        Respond with a coherent paragraph. No bullet points or lists.\
        """
      },
      %{
        role: :user,
        content: """
        Query: #{query}

        Known Facts:
        #{formatted_nodes}

        Synthesis:\
        """
      }
    ]
  end

  @impl true
  def parse_response(response) do
    case String.trim(response) do
      "" -> {:error, :empty_response}
      summary -> {:ok, summary}
    end
  end
end
