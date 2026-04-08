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
  @spec schema :: Zoi.Type.t()
  def schema do
    Zoi.map(
      %{
        facts:
          Zoi.list(
            Zoi.map(
              %{
                proposition: Zoi.string(),
                concepts: Zoi.list(Zoi.string()),
                confidence: Zoi.float()
              },
              coerce: true
            )
          )
      },
      coerce: true
    )
  end

  @impl true
  def build_messages(%{trajectory: trajectory, goal: goal} = variables) do
    overlay = if variables[:overlay], do: "\n\n#{variables.overlay}", else: ""

    formatted_steps =
      trajectory
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {step, i} ->
        "Step #{i}: Observed: #{step.observation} | Action: #{step.action} | Reward: #{step.reward}"
      end)

    [
      %{
        role: :system,
        content:
          """
          You are an expert at extracting factual knowledge from agent experiences.
          Given a trajectory segment, extract propositional knowledge — facts the agent
          learned from this experience.

          Quality constraints:
          - Coreference resolution: replace all pronouns with their explicit referents.
            Each proposition must be self-contained and interpretable without context.
          - Deduplication: if multiple steps yield the same fact, emit it once.
            Prefer the most specific formulation.
          - Atomicity: each proposition must express exactly one fact. No compound statements.

          For each fact, identify:
          - "concepts": key terms (entities, topics) the fact relates to, used as semantic indices
          - "confidence": your confidence in this proposition from 0.0 to 1.0
            (0.0 = uncertain/inferred, 1.0 = directly stated and unambiguous)

          Return your response as a JSON object with a "facts" array. Each fact has:
          - "proposition": a self-contained factual statement
          - "concepts": array of concept terms
          - "confidence": float between 0.0 and 1.0\
          """ <> overlay
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
         concepts: fact[:concepts] || [],
         confidence: parse_confidence(fact[:confidence])
       }
     end)}
  end

  def parse_response(_) do
    {:error, PromptError.exception(prompt: :get_semantic, reason: :no_facts_extracted)}
  end

  defp parse_confidence(val) when is_float(val) and val >= 0.0 and val <= 1.0, do: val
  defp parse_confidence(val) when is_number(val), do: max(0.0, min(1.0, val / 1))
  defp parse_confidence(_), do: 1.0
end
