defmodule Mnemosyne.ExtractionProfile do
  @moduledoc """
  Domain-specific extraction profiles that customize how knowledge is
  extracted, scored, and prioritized from episodes.

  Each profile provides prompt overlays injected into extraction prompts
  and optional value function parameter overrides.
  """

  @enforce_keys [:name]
  defstruct [:name, :domain_context, overlays: %{}, value_function_overrides: %{}]

  @type t :: %__MODULE__{
          name: atom(),
          domain_context: String.t(),
          overlays: %{atom() => String.t()},
          value_function_overrides: %{atom() => map()}
        }

  @doc "Returns a profile tuned for software engineering interactions."
  @spec coding() :: t()
  def coding do
    %__MODULE__{
      name: :coding,
      domain_context:
        "Software engineering interactions involving code, debugging, architecture, and system design.",
      overlays: %{
        get_semantic: """
        Domain: Software Engineering.
        Prioritize extracting: API behaviors and contracts, error patterns and their triggers,
        architectural constraints and design decisions, dependency relationships between components.
        When assessing confidence, weight empirically verified facts (code executed successfully,
        tests passed) higher than stated assumptions or intentions.
        De-prioritize: conversational filler, meta-commentary about process, IDE/tooling chatter
        unrelated to the codebase.\
        """,
        get_procedural: """
        Domain: Software Engineering.
        Focus on: debugging and troubleshooting steps, error resolution patterns,
        build/deploy/release procedures, code patterns and refactoring techniques.
        In the condition field, capture relevant language, framework, library version,
        and environment context (e.g., "When using Phoenix LiveView 0.20+ with streams").
        In expected_outcome, prefer observable outcomes (test passes, error disappears,
        build succeeds) over vague descriptions.\
        """,
        get_reward: """
        Domain: Software Engineering.
        Weight reward toward concrete outcomes: Did the code compile? Did tests pass?
        Was the bug resolved? Was the feature implemented correctly?
        Lower reward for actions that produced discussion but no working result.\
        """
      },
      value_function_overrides: %{
        procedural: %{base_floor: 0.15}
      }
    }
  end

  @doc "Returns a profile tuned for research and knowledge work."
  @spec research() :: t()
  def research do
    %__MODULE__{
      name: :research,
      domain_context: "Knowledge work involving research, analysis, and information synthesis.",
      overlays: %{
        get_semantic: """
        Domain: Research and Knowledge Work.
        Prioritize extracting: factual claims with their evidence basis, relationships between
        concepts or sources, contradictions or tensions between findings, methodological
        observations. Distinguish empirical findings from interpretations or speculation.
        When assessing confidence, weight primary source citations and reproducible findings
        higher than secondary summaries.\
        """,
        get_procedural: """
        Domain: Research and Knowledge Work.
        Extract only high-level methodologies, research strategies, and analytical frameworks.
        Do not extract granular step-by-step procedures unless they represent a novel technique.
        Focus on: search strategies, evaluation criteria, synthesis approaches.\
        """,
        get_reward: """
        Domain: Research and Knowledge Work.
        Weight reward toward information quality: Was the information novel and non-obvious?
        Was it accurate and well-sourced? Did it advance understanding of the topic?
        Lower reward for redundant information retrieval or tangential exploration.\
        """
      },
      value_function_overrides: %{
        semantic: %{base_floor: 0.15},
        procedural: %{base_floor: 0.05}
      }
    }
  end

  @doc "Returns a profile tuned for customer support interactions."
  @spec customer_support() :: t()
  def customer_support do
    %__MODULE__{
      name: :customer_support,
      domain_context:
        "Customer interactions involving issue resolution, product knowledge, and escalation.",
      overlays: %{
        get_semantic: """
        Domain: Customer Support.
        Prioritize extracting: product behaviors (expected and unexpected), known issues and
        their workarounds, policy rules and their boundary conditions, customer-reported symptoms
        and their root causes. When assessing confidence, weight confirmed reproductions and
        official documentation higher than single customer reports.\
        """,
        get_procedural: """
        Domain: Customer Support.
        Focus on: issue resolution workflows, diagnostic decision trees, escalation criteria
        and paths, workaround procedures. In the condition field, capture product version,
        plan tier, and symptom description (e.g., "When customer on Pro plan reports 503 errors
        on dashboard"). In expected_outcome, state the resolution or next escalation step.\
        """,
        get_reward: """
        Domain: Customer Support.
        Weight reward toward resolution: Was the customer's issue resolved? Was the correct
        resolution path identified? Were unnecessary escalations avoided?
        Lower reward for responses that required follow-up or led to circular troubleshooting.\
        """
      },
      value_function_overrides: %{
        procedural: %{base_floor: 0.12}
      }
    }
  end
end
