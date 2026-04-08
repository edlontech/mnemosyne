defmodule Mnemosyne.Pipeline.Prompts.GetReturn do
  @moduledoc """
  Prompt for scoring each prescription (procedural instruction) individually
  against its specific intent and the trajectory evidence.

  Per the PlugMem paper, each prescription is evaluated on a 1-10 scale
  assessing whether the intent was achieved and how well the prescription
  was executed. Scores are normalized to [0.0, 1.0] for internal use.

  Returns structured output via `chat_structured/3` using a Zoi schema.
  """

  alias Mnemosyne.Errors.Invalid.PromptError

  @doc "Returns the Zoi schema for structured LLM output validation."
  @spec schema :: Zoi.Type.t()
  def schema do
    Zoi.map(
      %{
        scores:
          Zoi.list(Zoi.map(%{index: Zoi.integer(), return_score: Zoi.integer()}, coerce: true))
      },
      coerce: true
    )
  end

  @doc "Builds the system and user messages for the return-scoring prompt."
  @spec build_messages(map()) :: [map()]
  def build_messages(
        %{trajectory: trajectory, goal: goal, prescriptions: prescriptions} = variables
      ) do
    overlay = if variables[:overlay], do: "\n\n#{variables.overlay}", else: ""

    formatted_steps =
      trajectory
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {step, i} ->
        parts = ["Step #{i}:"]
        parts = if step.state, do: parts ++ ["State: #{step.state}"], else: parts

        parts =
          parts ++
            [
              "Action: #{step.action}",
              "Observation: #{truncate(step.observation, 500)}",
              "Reward: #{step.reward}"
            ]

        Enum.join(parts, " | ")
      end)

    formatted_prescriptions =
      Enum.map_join(prescriptions, "\n\n", fn p ->
        "[#{p.index}] Intent: #{p.intent}\n" <>
          "  Instruction: #{p.instruction}\n" <>
          "  Condition: #{p.condition}\n" <>
          "  Expected outcome: #{p.expected_outcome}"
      end)

    [
      %{
        role: :system,
        content:
          """
          You are an expert at evaluating procedural prescription quality.
          For each prescription, assess whether its intent was achieved and how well
          the prescription was executed based on the trajectory evidence.

          Grading Criteria (Score 1-10):
          10: The prescription fully accomplishes its intent with no significant omissions.
          8-9: Most of the intent is achieved with only minor gaps.
          6-7: Partial completion; key elements covered but notable parts unfinished.
          4-5: Limited progress; less than half achieved or done ineffectively.
          2-3: Very little completion; actions barely connect to the intent.
          1: No meaningful progress toward the intent.

          Base the score only on completion level and alignment with the stated intent.
          Evaluate each prescription independently against the trajectory evidence.

          Return a JSON object with a "scores" array. Each entry has:
          - "index": the prescription index (integer)
          - "return_score": an integer from 1 to 10\
          """ <> overlay
      },
      %{
        role: :user,
        content: """
        Goal: #{goal}

        Trajectory (#{length(trajectory)} steps):
        #{formatted_steps}

        Prescriptions to evaluate:
        #{formatted_prescriptions}

        Score each prescription independently:\
        """
      }
    ]
  end

  @doc "Parses and normalizes the scored prescriptions from the LLM response."
  @spec parse_response(map()) :: {:ok, [map()]} | {:error, PromptError.t()}
  def parse_response(%{scores: [_ | _] = scores}) do
    normalized =
      Enum.map(scores, fn %{index: idx, return_score: score} ->
        %{index: idx, return_score: normalize(score)}
      end)

    {:ok, normalized}
  end

  def parse_response(_) do
    {:error, PromptError.exception(prompt: :get_return, reason: :no_scores_extracted)}
  end

  defp normalize(score) when is_integer(score), do: normalize(score / 1)
  defp normalize(score) when score < 1.0, do: 0.0
  defp normalize(score) when score > 10.0, do: 1.0
  defp normalize(score), do: Float.round((score - 1.0) / 9.0, 4)

  defp truncate(nil, _max), do: ""
  defp truncate(text, max) when byte_size(text) <= max, do: text
  defp truncate(text, max), do: String.slice(text, 0, max) <> "..."
end
