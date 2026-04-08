defmodule Mnemosyne.Pipeline.Prompts.GetSubgoal do
  @moduledoc """
  Prompt for inferring what sub-goal the agent is pursuing given the
  current state, observation, action, and overall goal.

  Implements `g_t = f(s_t, o_t, a_t, G)` — conditioning subgoal inference
  on the derived state ensures the inferred intent reflects accumulated context,
  not just the immediate observation.

  Returns structured output via `chat_structured/3` using a Zoi schema.
  """

  @behaviour Mnemosyne.Prompt

  alias Mnemosyne.Errors.Invalid.PromptError

  @spec schema :: Zoi.Type.t()
  def schema do
    Zoi.map(
      %{
        reasoning: Zoi.string(),
        subgoal: Zoi.string()
      },
      coerce: true
    )
  end

  @system_prompt """
  At time t, the agent takes an action based on its state, observation, and overall goal.
  Your task is to infer the subgoal -- the immediate or intermediate objective -- that
  best explains why the agent chose this action.

  Step 1: Reasoning
  Analyze how the current state and observation relate to the overall goal.
  Explain how the given action helps the agent make progress toward that goal,
  possibly by achieving a smaller intermediate objective. Be explicit and causal:
  describe why this action makes sense given the context.

  Step 2: Subgoal Inference
  After reasoning, infer the agent's likely subgoal -- a short natural-language
  statement that describes the immediate purpose behind the action.\
  """

  @impl true
  def build_messages(
        %{observation: observation, action: action, goal: goal, state: nil} = variables
      ) do
    overlay = if variables[:overlay], do: "\n\n#{variables.overlay}", else: ""

    [
      %{role: :system, content: @system_prompt <> overlay},
      %{
        role: :user,
        content: """
        Overall Goal: #{goal}
        Current State (summary of past context): [initial state - no prior context]
        Current Observation: #{observation}
        Action at time t: #{action}\
        """
      }
    ]
  end

  def build_messages(
        %{observation: observation, action: action, goal: goal, state: state} = variables
      ) do
    overlay = if variables[:overlay], do: "\n\n#{variables.overlay}", else: ""

    [
      %{role: :system, content: @system_prompt <> overlay},
      %{
        role: :user,
        content: """
        Overall Goal: #{goal}
        Current State (summary of past context): #{state}
        Current Observation: #{observation}
        Action at time t: #{action}\
        """
      }
    ]
  end

  @impl true
  def parse_response(%{"subgoal" => subgoal}) when is_binary(subgoal) do
    case String.trim(subgoal) do
      "" -> {:error, PromptError.exception(prompt: :get_subgoal, reason: :empty_response)}
      trimmed -> {:ok, trimmed}
    end
  end

  def parse_response(_),
    do: {:error, PromptError.exception(prompt: :get_subgoal, reason: :invalid_schema)}
end
