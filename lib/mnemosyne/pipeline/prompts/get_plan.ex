defmodule Mnemosyne.Pipeline.Prompts.GetPlan do
  @moduledoc """
  Prompt for generating retrieval tags from a query and its classified mode.
  Produces a list of search tags used to query the knowledge graph.
  """

  @behaviour Mnemosyne.Prompt

  @impl true
  def build_messages(%{query: query, mode: mode}) do
    [
      %{
        role: :system,
        content: """
        You are an expert at planning memory retrieval strategies.
        Given a query and its classified memory mode, generate a list of search tags
        that would help find relevant memories in a knowledge graph.

        Tags should be concise noun phrases or key concepts.
        Respond with one tag per line. No numbering or bullet points.\
        """
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
      [] -> {:error, :no_tags_generated}
      tags -> {:ok, tags}
    end
  end
end
