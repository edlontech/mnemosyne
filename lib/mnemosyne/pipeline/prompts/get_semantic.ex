defmodule Mnemosyne.Pipeline.Prompts.GetSemantic do
  @moduledoc """
  Prompt for extracting propositional knowledge (facts learned)
  from a trajectory segment.
  """

  @behaviour Mnemosyne.Prompt

  alias Mnemosyne.Errors.Invalid.PromptError

  @impl true
  def build_messages(%{trajectory: trajectory, goal: goal}) do
    formatted_steps =
      trajectory
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {step, i} ->
        "Step #{i}: Observed: #{step.observation} | Action: #{step.action} | Reward: #{step.reward}"
      end)

    [
      %{
        role: :system,
        content: """
        You are an expert at extracting factual knowledge from agent experiences.
        Given a trajectory segment, extract propositional knowledge — facts the agent
        learned from this experience.

        Respond with one fact per line. Each fact should be a self-contained proposition.
        Do not number them or use bullet points. Just plain text, one per line.\
        """
      },
      %{
        role: :user,
        content: """
        Goal: #{goal}

        Trajectory Segment:
        #{formatted_steps}

        Facts learned:\
        """
      }
    ]
  end

  @impl true
  def parse_response(response) do
    facts =
      response
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case facts do
      [] -> {:error, PromptError.exception(prompt: :get_semantic, reason: :no_facts_extracted)}
      facts -> {:ok, facts}
    end
  end
end
