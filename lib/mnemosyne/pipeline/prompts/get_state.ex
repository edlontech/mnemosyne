defmodule Mnemosyne.Pipeline.Prompts.GetState do
  @moduledoc """
  Prompt for deriving progressive environment state from a single step.

  Implements `s_t = f(s_{t-1}, a_{t-1}, o_t)` — each step's state is derived
  from the previous state, the previous action, and the new observation.
  The first step has no history, so `s_1` is derived from the goal and `o_1` only.
  """

  @behaviour Mnemosyne.Prompt

  alias Mnemosyne.Errors.Invalid.PromptError

  @impl true
  def build_messages(%{previous_state: nil, observation: observation, goal: goal} = variables) do
    overlay = if variables[:overlay], do: "\n\n#{variables.overlay}", else: ""

    [
      %{
        role: :system,
        content:
          """
          You are an expert at deriving environment state from agent interactions.
          Given the agent's goal and its initial observation, derive the current environment state.

          Respond with ONLY the state summary as a brief paragraph. No explanation.\
          """ <> overlay
      },
      %{
        role: :user,
        content: """
        Goal: #{goal}

        Observation: #{observation}

        Current environment state:\
        """
      }
    ]
  end

  def build_messages(
        %{
          previous_state: prev,
          action: action,
          observation: observation,
          goal: goal
        } = variables
      ) do
    overlay = if variables[:overlay], do: "\n\n#{variables.overlay}", else: ""

    [
      %{
        role: :system,
        content:
          """
          You are an expert at deriving environment state from agent interactions.
          Given the previous environment state, the action the agent then took, and the resulting observation, derive the updated environment state.

          Respond with ONLY the state summary as a brief paragraph. No explanation.\
          """ <> overlay
      },
      %{
        role: :user,
        content: """
        Goal: #{goal}

        Previous state: #{prev}
        Action: #{action}
        Observation: #{observation}

        Updated environment state:\
        """
      }
    ]
  end

  @impl true
  def parse_response(response) do
    case String.trim(response) do
      "" -> {:error, PromptError.exception(prompt: :get_state, reason: :empty_response)}
      state -> {:ok, state}
    end
  end
end
