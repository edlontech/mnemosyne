defmodule Mnemosyne.TestPrompts do
  @moduledoc false

  @doc "True when `messages` is the AnnotateSteps prompt."
  def annotating?(messages) do
    Enum.any?(messages, &(&1.role == :system and &1.content =~ "analysing agent trajectories"))
  end

  @doc """
  Builds an AnnotateSteps response that answers every step listed in `messages`.

  The state echoes the step's observation as `"state after: <observation>"`.
  `:subgoal` sets one subgoal for all steps, or a map from an action substring
  to its subgoal.
  """
  def annotations(messages, opts \\ []) do
    user = Enum.find(messages, &(&1.role == :user)).content
    subgoal = Keyword.get(opts, :subgoal, "test subgoal")

    steps =
      ~r/^Step (\d+):\nObservation: (.*)\nAction: (.*)$/m
      |> Regex.scan(user)
      |> Enum.map(fn [_, number, observation, action] ->
        %{
          step: String.to_integer(number),
          state: "state after: #{observation}",
          subgoal: subgoal_for(subgoal, action)
        }
      end)

    %{steps: steps}
  end

  defp subgoal_for(subgoal, _action) when is_binary(subgoal), do: subgoal

  defp subgoal_for(subgoals, action) do
    Enum.find_value(subgoals, "default subgoal", fn {fragment, subgoal} ->
      if action =~ fragment, do: subgoal
    end)
  end
end
