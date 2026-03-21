defmodule Mnemosyne.Pipeline.Prompts.GetReturn do
  @moduledoc """
  Prompt for scoring each prescription (procedural instruction) in a trajectory
  by how well it contributed to the goal.

  Returns structured output via `chat_structured/3` using a Zoi schema.
  """

  alias Mnemosyne.Errors.Invalid.PromptError

  @doc "Returns the Zoi schema for structured LLM output validation."
  @spec schema :: Zoi.Type.t()
  def schema do
    Zoi.map(
      %{
        scores:
          Zoi.list(Zoi.map(%{index: Zoi.integer(), return_score: Zoi.float()}, coerce: true))
      },
      coerce: true
    )
  end

  @doc "Builds the system and user messages for the return-scoring prompt."
  @spec build_messages(map()) :: [map()]
  def build_messages(%{trajectory: trajectory, goal: goal, prescriptions: prescriptions}) do
    formatted_steps =
      trajectory
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {step, i} ->
        "Step #{i}: Action: #{step.action} | Reward: #{step.reward}"
      end)

    formatted_prescriptions =
      Enum.map_join(prescriptions, "\n", fn p ->
        "[#{p.index}] Instruction: #{p.instruction} | Condition: #{p.condition} | Expected: #{p.expected_outcome}"
      end)

    [
      %{
        role: :system,
        content: """
        You are an expert at evaluating prescription quality for reinforcement learning.
        Given a trajectory segment with per-step rewards, the overall goal, and a list of
        prescriptions extracted from the trajectory, score each prescription by how well
        it contributed to goal achievement.

        Return a JSON object with a "scores" array. Each entry has:
        - "index": the prescription index (integer)
        - "return_score": a float between 0.0 and 1.0\
        """
      },
      %{
        role: :user,
        content: """
        Goal: #{goal}

        Trajectory (#{length(trajectory)} steps):
        #{formatted_steps}

        Prescriptions:
        #{formatted_prescriptions}

        Score each prescription:\
        """
      }
    ]
  end

  @doc "Parses and clamps the scored prescriptions from the LLM response."
  @spec parse_response(map()) :: {:ok, [map()]} | {:error, PromptError.t()}
  def parse_response(%{scores: [_ | _] = scores}) do
    clamped =
      Enum.map(scores, fn %{index: idx, return_score: score} ->
        %{index: idx, return_score: clamp(score)}
      end)

    {:ok, clamped}
  end

  def parse_response(_) do
    {:error, PromptError.exception(prompt: :get_return, reason: :no_scores_extracted)}
  end

  defp clamp(value) when value < 0.0, do: 0.0
  defp clamp(value) when value > 1.0, do: 1.0
  defp clamp(value), do: value
end
