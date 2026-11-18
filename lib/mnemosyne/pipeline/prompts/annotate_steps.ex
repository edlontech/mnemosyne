defmodule Mnemosyne.Pipeline.Prompts.AnnotateSteps do
  @moduledoc """
  Prompt that derives the environment state and the subgoal for a window of
  consecutive steps in one call.

  For each step `t` the state is `s_t = f(s_{t-1}, a_{t-1}, o_t)` and the
  subgoal is `g_t = f(s_t, o_t, a_t, G)`. The state before the window's first
  step is carried in from the previous window, so windows chain while the
  steps inside one window share a single request.

  Returns structured output via `chat_structured/3` using a Zoi schema.
  """

  alias Mnemosyne.Errors.Invalid.PromptError

  @doc "Returns the Zoi schema for structured LLM output validation."
  @spec schema :: Zoi.Type.t()
  def schema do
    Zoi.map(
      %{
        steps:
          Zoi.list(
            Zoi.map(%{step: Zoi.integer(), state: Zoi.string(), subgoal: Zoi.string()},
              coerce: true
            )
          )
      },
      coerce: true
    )
  end

  @doc """
  Builds the system and user messages for a window of steps.

  `steps` is a list of `%{number: pos_integer(), observation: String.t(), action: String.t()}`.
  `previous` is `nil` for the first window, or the `%{state: ..., action: ...}` of the
  step right before this window.
  """
  @spec build_messages(map()) :: [map()]
  def build_messages(%{steps: steps, goal: goal, previous: previous} = variables) do
    overlay = if variables[:overlay], do: "\n\n#{variables.overlay}", else: ""

    formatted_steps =
      Enum.map_join(steps, "\n\n", fn step ->
        "Step #{step.number}:\nObservation: #{step.observation}\nAction: #{step.action}"
      end)

    [
      %{
        role: :system,
        content:
          """
          You are an expert at analysing agent trajectories.
          You are given the agent's overall goal, the environment state before the
          listed steps, and a numbered sequence of steps. In each step the agent
          receives an observation and then takes an action.

          For every step, in order, produce:
          - "state": the environment state once the step's observation is known and
            before its action is taken, as a concise paragraph. Derive it from the
            preceding state, the preceding action and this observation. Keep the
            specific details, especially names, places and times.
          - "subgoal": a short natural-language statement of the immediate or
            intermediate objective that best explains why the agent took this step's
            action, given that state and the overall goal.

          Return a JSON object with a "steps" array holding exactly one entry per
          listed step, in the same order. Each entry has:
          - "step": the step number as given
          - "state": the state summary
          - "subgoal": the inferred subgoal\
          """ <> overlay
      },
      %{
        role: :user,
        content: """
        Goal: #{goal}#{occurred_line(variables[:occurred_at])}

        #{previous_block(previous)}

        #{formatted_steps}\
        """
      }
    ]
  end

  @doc """
  Returns the annotations for `numbers`, in that order.

  Fails with `:incomplete_steps` when any requested step is missing or has a
  blank state or subgoal, so the caller can retry with a smaller window.
  """
  @spec parse_response(term(), [pos_integer()]) ::
          {:ok, [%{state: String.t(), subgoal: String.t()}]} | {:error, PromptError.t()}
  def parse_response(%{steps: steps}, numbers) when is_list(steps) do
    by_number =
      for %{step: number, state: state, subgoal: subgoal} <- steps,
          is_binary(state) and is_binary(subgoal),
          state = String.trim(state),
          subgoal = String.trim(subgoal),
          state != "" and subgoal != "",
          into: %{},
          do: {number, %{state: state, subgoal: subgoal}}

    annotations = Enum.map(numbers, &Map.get(by_number, &1))

    if Enum.any?(annotations, &is_nil/1), do: incomplete(), else: {:ok, annotations}
  end

  def parse_response(_response, _numbers), do: incomplete()

  defp incomplete,
    do: {:error, PromptError.exception(prompt: :annotate_steps, reason: :incomplete_steps)}

  defp previous_block(nil),
    do: "State before the first listed step: [initial state - no prior context]"

  defp previous_block(%{state: state, action: action}) do
    "State before the first listed step: #{state}\nAction taken from that state: #{action}"
  end

  defp occurred_line(nil), do: ""

  defp occurred_line(%DateTime{} = occurred_at),
    do: "\nOccurred at: #{Calendar.strftime(occurred_at, "%A, %Y-%m-%d %H:%M")}"
end
