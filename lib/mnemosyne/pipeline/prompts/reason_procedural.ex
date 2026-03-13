defmodule Mnemosyne.Pipeline.Prompts.ReasonProcedural do
  @moduledoc """
  Prompt for synthesizing retrieved procedural memory nodes
  into actionable instructions relevant to the query.
  """

  @behaviour Mnemosyne.Prompt

  alias Mnemosyne.Errors.Invalid.PromptError

  @impl true
  def build_messages(%{query: query, nodes: nodes}) do
    formatted_nodes =
      nodes
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {node, i} ->
        "Procedure #{i}: WHEN #{node.condition} DO #{node.instruction} EXPECT #{node.expected_outcome}"
      end)

    [
      %{
        role: :system,
        content: """
        You are an expert at synthesizing procedural knowledge into actionable guidance.
        Given a query and a set of known procedures, produce a concise summary of
        relevant instructions that address the query.

        Order steps logically. Highlight conditions under which procedures apply.
        Respond with a coherent paragraph. No bullet points or lists.\
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
  def parse_response(response) do
    case String.trim(response) do
      "" -> {:error, PromptError.exception(prompt: :reason_procedural, reason: :empty_response)}
      summary -> {:ok, summary}
    end
  end
end
