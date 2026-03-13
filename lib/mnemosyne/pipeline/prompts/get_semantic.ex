defmodule Mnemosyne.Pipeline.Prompts.GetSemantic do
  @moduledoc """
  Prompt for extracting propositional knowledge (facts learned)
  from a trajectory segment, along with associated concept terms
  that serve as semantic routing indices.

  Returns structured output via `chat_structured/3` using a Zoi schema.
  """

  @behaviour Mnemosyne.Prompt

  alias Mnemosyne.Errors.Invalid.PromptError

  @doc "Returns the Zoi schema for structured LLM output validation."
  @spec schema :: Zoi.Types.Map.t()
  def schema do
    Zoi.map(
      %{
        facts:
          Zoi.list(
            Zoi.map(
              %{
                proposition: Zoi.string(),
                concepts: Zoi.list(Zoi.string())
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
        You are an expert at extracting factual knowledge from agent experiences.
        Given a trajectory segment, extract propositional knowledge — facts the agent
        learned from this experience.

        For each fact, also identify the key concepts (entities, terms, topics) that
        the fact relates to. These concepts serve as semantic indices for retrieval.

        Return your response as a JSON object with a "facts" array. Each fact has:
        - "proposition": a self-contained factual statement
        - "concepts": array of concept terms (entities, topics) related to the fact\
        """
      },
      %{
        role: :user,
        content: """
        Goal: #{goal}

        Trajectory Segment:
        #{formatted_steps}

        Facts learned:\
        """
      }
    ]
  end

  @impl true
  def parse_response(%{facts: [_ | _] = facts}) do
    {:ok,
     Enum.map(facts, fn fact ->
       %{
         proposition: fact[:proposition],
         concepts: fact[:concepts] || []
       }
     end)}
  end

  def parse_response(_) do
    {:error, PromptError.exception(prompt: :get_semantic, reason: :no_facts_extracted)}
  end
end
