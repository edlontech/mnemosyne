defmodule Mnemosyne.Pipeline.Prompts.GetReturn do
  @moduledoc """
  Prompt for computing the return value of a trajectory segment
  based on rewards and overall trajectory quality.
  """

  @behaviour Mnemosyne.Prompt

  @impl true
  def build_messages(%{trajectory: trajectory, goal: goal}) do
    formatted_steps =
      trajectory
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {step, i} ->
        "Step #{i}: Action: #{step.action} | Reward: #{step.reward}"
      end)

    avg_reward =
      case trajectory do
        [] -> 0.0
        steps -> Enum.sum(Enum.map(steps, & &1.reward)) / length(steps)
      end

    [
      %{
        role: :system,
        content: """
        You are an expert at evaluating trajectory quality for reinforcement learning.
        Given a trajectory segment with per-step rewards and the overall goal,
        compute a single return value that reflects the overall quality and
        goal-alignment of this trajectory segment.

        Consider both the individual rewards and whether the sequence of actions
        made meaningful progress toward the goal.

        Respond with ONLY a decimal number between 0.0 and 1.0.\
        """
      },
      %{
        role: :user,
        content: """
        Goal: #{goal}

        Trajectory (#{length(trajectory)} steps, avg reward: #{Float.round(avg_reward, 3)}):
        #{formatted_steps}

        Return value (0.0-1.0):\
        """
      }
    ]
  end

  @impl true
  def parse_response(response) do
    response
    |> String.trim()
    |> Float.parse()
    |> case do
      {value, _} when value >= 0.0 and value <= 1.0 -> {:ok, value}
      {value, _} -> {:ok, clamp(value)}
      :error -> {:error, :invalid_float}
    end
  end

  defp clamp(value) when value < 0.0, do: 0.0
  defp clamp(value) when value > 1.0, do: 1.0
  defp clamp(value), do: value
end
