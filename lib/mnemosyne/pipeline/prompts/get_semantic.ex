defmodule Mnemosyne.Pipeline.Prompts.GetSemantic do
  @moduledoc """
  Prompt for extracting propositional knowledge (facts learned)
  from a trajectory segment, along with associated concept terms
  that serve as semantic routing indices.

  Each fact carries the step numbers it derives from so that
  provenance and sibling links can be created at the episodic-unit
  level rather than the whole trajectory.

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
                confidence: Zoi.float(),
                source_steps: Zoi.list(Zoi.integer())
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

          Statement rules:
          - Resolve vague references: if the subject of a statement is a pronoun or a
            vague description (e.g. "the file", "the service", "it", "they"), rewrite it
            so the subject is a fully specified, concrete name taken from the trajectory.
            You are NOT allowed to keep vague subjects in the final statement.
          - A statement does NOT have to be a single short sentence. It MAY be a compact
            multi-sentence block that groups tightly related information, but it must
            contain AT MOST 4 sentences total.
          - Avoid redundancy: MERGE similar or overlapping facts into single,
            comprehensive statements. Do NOT create multiple statements that repeat the
            same core information with minor variations.
          - Extract up to 10 facts, prioritizing QUALITY over quantity. If there are
            fewer than 10 truly distinct facts, output fewer. Each fact must provide
            unique information not covered by other facts.

          Concept rules:
          - For each fact, generate a list of concept terms used as semantic indices.
          - The MAJORITY of concepts SHOULD be SHORT TEXT SPANS copied VERBATIM from the
            statement (exact substrings): entity names, years, numbers, roles, object
            types, descriptive words.
          - When the original subject was vague, you MUST include at least one concept
            naming the underlying entity explicitly.
          - If a concept is a verb, use its base (lemma) form (e.g. "deploy", not
            "deployed" or "deploying").
          - NO schema or type labels: you are FORBIDDEN from using meta-labels such as
            "Name", "Person", "Year", "Date", "Location", "Category". Concepts are
            content-bearing phrases, not type names.

          For each fact, also identify:
          - "confidence": your confidence in this proposition from 0.0 to 1.0
            (0.0 = uncertain/inferred, 1.0 = directly stated and unambiguous)
          - "source_steps": the step numbers (as shown in the trajectory) the fact was
            derived from

          Return your response as a JSON object with a "facts" array. Each fact has:
          - "proposition": a self-contained factual statement
          - "concepts": array of concept terms
          - "confidence": float between 0.0 and 1.0
          - "source_steps": array of step numbers (integers)\
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
         confidence: parse_confidence(fact[:confidence]),
         source_steps: parse_source_steps(fact[:source_steps])
       }
     end)}
  end

  def parse_response(_) do
    {:error, PromptError.exception(prompt: :get_semantic, reason: :no_facts_extracted)}
  end

  defp parse_confidence(val) when is_float(val) and val >= 0.0 and val <= 1.0, do: val
  defp parse_confidence(val) when is_number(val), do: max(0.0, min(1.0, val / 1))
  defp parse_confidence(_), do: 1.0

  defp parse_source_steps(steps) when is_list(steps) do
    steps |> Enum.filter(&(is_integer(&1) and &1 >= 1)) |> Enum.uniq()
  end

  defp parse_source_steps(_), do: []
end
