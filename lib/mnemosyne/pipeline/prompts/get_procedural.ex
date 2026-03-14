defmodule Mnemosyne.Pipeline.Prompts.GetProcedural do
  @moduledoc """
  Prompt for extracting prescriptive knowledge (instructions for future)
  from a trajectory segment.

  Returns structured output via `chat_structured/3` using a Zoi schema.
  """

  @behaviour Mnemosyne.Prompt

  alias Mnemosyne.Errors.Invalid.PromptError

  @doc "Returns the Zoi schema for structured LLM output validation."
  @spec schema :: Zoi.Type.t()
  def schema do
    Zoi.map(
      %{
        instructions:
          Zoi.list(
            Zoi.map(
              %{
                intent: Zoi.string(),
                condition: Zoi.string(),
                instruction: Zoi.string(),
                expected_outcome: Zoi.string()
              },
              coerce: true
            )
          )
      },
      coerce: true
    )
  end

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
        You are an expert at extracting actionable instructions from agent experiences.
        Given a trajectory segment, extract prescriptive knowledge — conditional instructions
        the agent should follow in similar future situations.

        For each instruction, also identify the high-level intent (user goal) that this
        instruction addresses. Intents serve as routing indices for retrieval.

        Return your response as a JSON object with an "instructions" array. Each instruction has:
        - "intent": the high-level goal this addresses
        - "condition": when to apply this instruction
        - "instruction": what to do
        - "expected_outcome": the expected result\
        """
      },
      %{
        role: :user,
        content: """
        Goal: #{goal}

        Trajectory Segment:
        #{formatted_steps}

        Instructions learned:\
        """
      }
    ]
  end

  @impl true
  def parse_response(%{instructions: [_ | _] = instructions}) do
    {:ok,
     Enum.map(instructions, fn instr ->
       %{
         intent: instr[:intent],
         condition: instr[:condition],
         instruction: instr[:instruction],
         expected_outcome: instr[:expected_outcome]
       }
     end)}
  end

  def parse_response(_) do
    {:error, PromptError.exception(prompt: :get_procedural, reason: :no_instructions_extracted)}
  end
end
