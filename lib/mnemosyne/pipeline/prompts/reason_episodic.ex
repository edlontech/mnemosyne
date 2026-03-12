defmodule Mnemosyne.Pipeline.Prompts.ReasonEpisodic do
  @moduledoc """
  Prompt for synthesizing retrieved episodic memory nodes
  into a coherent narrative summary relevant to the query.
  """

  @behaviour Mnemosyne.Prompt

  @impl true
  def build_messages(%{query: query, nodes: nodes}) do
    formatted_nodes =
      nodes
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {node, i} ->
        "Episode #{i}: Observed: #{node.observation} | Action: #{node.action} | State: #{node.state} | Reward: #{node.reward}"
      end)

    [
      %{
        role: :system,
        content: """
        You are an expert at synthesizing episodic memories into relevant narratives.
        Given a query and a set of past experiences, produce a concise summary that
        addresses the query by drawing on the most relevant episodes.

        Focus on temporal sequence and causal relationships between events.
        Respond with a coherent paragraph. No bullet points or lists.\
        """
      },
      %{
        role: :user,
        content: """
        Query: #{query}

        Retrieved Episodes:
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
