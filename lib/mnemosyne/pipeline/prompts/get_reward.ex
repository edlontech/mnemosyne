defmodule Mnemosyne.Pipeline.Prompts.GetReward do
  @moduledoc """
  Prompt for evaluating how well a step serves the current sub-goal.
  Returns a reward score between 0.0 and 1.0.
  """

  @behaviour Mnemosyne.Prompt

  alias Mnemosyne.Errors.Invalid.PromptError

  @impl true
  def build_messages(
        %{
          observation: observation,
          action: action,
          subgoal: subgoal,
          next_observation: next_observation
        } = variables
      ) do
    overlay = if variables[:overlay], do: "\n\n#{variables.overlay}", else: ""

    [
      %{
        role: :system,
        content:
          """
          You are an expert at evaluating agent performance.
          Given an observation, action, the sub-goal being pursued, and the
          outcome that was observed after the action, rate how well this
          action served the sub-goal.

          Respond with ONLY a decimal number between 0.0 and 1.0.
          0.0 = completely counterproductive
          0.5 = neutral or uncertain
          1.0 = perfectly serves the sub-goal\
          """ <> overlay
      },
      %{
        role: :user,
        content: """
        Sub-goal: #{subgoal}

        Observation: #{observation}

        Action: #{action}

        Outcome observed after action: #{next_observation}

        Score (0.0-1.0):\
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
      :error -> {:error, PromptError.exception(prompt: :get_reward, reason: :invalid_float)}
    end
  end

  defp clamp(value) when value < 0.0, do: 0.0
  defp clamp(value) when value > 1.0, do: 1.0
  defp clamp(value), do: value
end
