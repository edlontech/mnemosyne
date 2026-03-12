defmodule Mnemosyne.Pipeline.Prompts.GetSubgoal do
  @moduledoc """
  Prompt for inferring what sub-goal the agent is pursuing
  given the current observation, action, and overall goal.
  """

  @behaviour Mnemosyne.Prompt

  @impl true
  def build_messages(%{observation: observation, action: action, goal: goal}) do
    [
      %{
        role: :system,
        content: """
        You are an expert at analyzing agent behavior and inferring intent.
        Given an agent's observation, action, and overall goal, identify the specific
        sub-goal the agent is currently pursuing.

        Respond with ONLY the sub-goal as a single concise sentence. No explanation.\
        """
      },
      %{
        role: :user,
        content: """
        Overall Goal: #{goal}

        Current Observation: #{observation}

        Action Taken: #{action}

        What specific sub-goal is the agent pursuing with this action?\
        """
      }
    ]
  end

  @impl true
  def parse_response(response) do
    case String.trim(response) do
      "" -> {:error, :empty_response}
      subgoal -> {:ok, subgoal}
    end
  end
end
