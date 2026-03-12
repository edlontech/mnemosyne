defmodule Mnemosyne.Pipeline.Prompts.GetProcedural do
  @moduledoc """
  Prompt for extracting prescriptive knowledge (instructions for future)
  from a trajectory segment.
  """

  @behaviour Mnemosyne.Prompt

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

        Respond in the following format, one instruction per block, separated by blank lines:

        WHEN: <condition>
        DO: <instruction>
        EXPECT: <expected outcome>\
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
  def parse_response(response) do
    instructions =
      response
      |> String.split(~r/\n\s*\n/)
      |> Enum.map(&parse_instruction_block/1)
      |> Enum.reject(&is_nil/1)

    case instructions do
      [] -> {:error, :no_instructions_extracted}
      instructions -> {:ok, instructions}
    end
  end

  defp parse_instruction_block(block) do
    lines =
      block
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    with {:ok, condition} <- extract_field(lines, "WHEN:"),
         {:ok, instruction} <- extract_field(lines, "DO:"),
         {:ok, expected_outcome} <- extract_field(lines, "EXPECT:") do
      %{condition: condition, instruction: instruction, expected_outcome: expected_outcome}
    else
      _ -> nil
    end
  end

  defp extract_field(lines, prefix) do
    lines
    |> Enum.find_value(fn line ->
      case String.split(line, prefix, parts: 2) do
        [_, value] -> {:ok, String.trim(value)}
        _ -> nil
      end
    end)
    |> case do
      {:ok, _} = result -> result
      nil -> :error
    end
  end
end
