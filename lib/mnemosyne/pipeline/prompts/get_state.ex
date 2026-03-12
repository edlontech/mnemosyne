defmodule Mnemosyne.Pipeline.Prompts.GetState do
  @moduledoc """
  Prompt for summarizing the current environment state
  from a trajectory of observation-action pairs.
  """

  @behaviour Mnemosyne.Prompt

  @impl true
  def build_messages(%{trajectory: trajectory, goal: goal}) do
    formatted_steps =
      trajectory
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {step, i} ->
        "Step #{i}: Observed: #{step.observation} | Action: #{step.action}"
      end)

    [
      %{
        role: :system,
        content: """
        You are an expert at summarizing environment state from agent trajectories.
        Given a sequence of observation-action pairs and the agent's goal,
        provide a concise summary of the current environment state.

        Respond with ONLY the state summary as a brief paragraph. No explanation.\
        """
      },
      %{
        role: :user,
        content: """
        Goal: #{goal}

        Trajectory:
        #{formatted_steps}

        Current environment state summary:\
        """
      }
    ]
  end

  @impl true
  def parse_response(response) do
    case String.trim(response) do
      "" -> {:error, :empty_response}
      state -> {:ok, state}
    end
  end
end
