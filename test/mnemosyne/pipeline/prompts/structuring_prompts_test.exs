defmodule Mnemosyne.Pipeline.Prompts.StructuringPromptsTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Errors.Invalid.PromptError
  alias Mnemosyne.Pipeline.Prompts.AnnotateSteps
  alias Mnemosyne.Pipeline.Prompts.GetProcedural
  alias Mnemosyne.Pipeline.Prompts.GetReturn
  alias Mnemosyne.Pipeline.Prompts.GetReward
  alias Mnemosyne.Pipeline.Prompts.GetSemantic

  describe "AnnotateSteps" do
    @steps [
      %{number: 3, observation: "Slow query found", action: "Added index"},
      %{number: 4, observation: "Index applied", action: "Ran benchmark"}
    ]

    test "build_messages lists the numbered steps and marks the first window as initial" do
      messages =
        AnnotateSteps.build_messages(%{
          steps: @steps,
          goal: "Optimize",
          previous: nil,
          overlay: "Focus on API contracts."
        })

      assert [%{role: :system, content: system}, %{role: :user, content: user}] = messages
      assert system =~ "Focus on API contracts."
      assert user =~ "Goal: Optimize"
      assert user =~ "[initial state - no prior context]"
      assert user =~ "Step 3:\nObservation: Slow query found\nAction: Added index"
      assert user =~ "Step 4:\nObservation: Index applied\nAction: Ran benchmark"
    end

    test "build_messages carries the preceding state, action and event time" do
      [_, %{content: user}] =
        AnnotateSteps.build_messages(%{
          steps: @steps,
          goal: "Optimize",
          previous: %{state: "DB is slow", action: "Ran EXPLAIN"},
          occurred_at: ~U[2023-04-10 07:43:00Z]
        })

      assert user =~ "State before the first listed step: DB is slow"
      assert user =~ "Action taken from that state: Ran EXPLAIN"
      assert user =~ "Occurred at: Monday, 2023-04-10 07:43"
    end

    test "parse_response returns trimmed annotations in the requested order" do
      response = %{
        steps: [
          %{step: 4, state: " after index ", subgoal: "Measure"},
          %{step: 3, state: "slow", subgoal: " Speed up "}
        ]
      }

      assert {:ok, [%{state: "slow", subgoal: "Speed up"}, %{state: "after index"}]} =
               AnnotateSteps.parse_response(response, [3, 4])
    end

    test "parse_response rejects a missing step or a blank field" do
      incomplete = %{steps: [%{step: 3, state: "slow", subgoal: "Speed up"}]}
      blank = %{steps: [%{step: 3, state: "  ", subgoal: "Speed up"}]}

      for {response, numbers} <- [{incomplete, [3, 4]}, {blank, [3]}, {%{}, [3]}] do
        assert {:error, %PromptError{reason: :incomplete_steps}} =
                 AnnotateSteps.parse_response(response, numbers)
      end
    end
  end

  describe "GetReward" do
    test "build_messages appends overlay to system message when provided" do
      messages =
        GetReward.build_messages(%{
          state: "Server responded 200",
          action: "Send GET request",
          subgoal: "Verify API health",
          next_observation: "Dashboard shows green",
          overlay: "Evaluate strictly."
        })

      assert [%{role: :system, content: system}, _] = messages
      assert system =~ "Evaluate strictly."
    end

    test "build_messages includes subgoal, state, action, and next observation" do
      messages =
        GetReward.build_messages(%{
          state: "Server responded 200",
          action: "Send GET request",
          subgoal: "Verify API health",
          next_observation: "Dashboard shows green"
        })

      assert [%{role: :system}, %{role: :user, content: user}] = messages
      assert user =~ "Verify API health"
      assert user =~ "Server responded 200"
      assert user =~ "Send GET request"
      assert user =~ "Dashboard shows green"
    end

    test "parse_response extracts valid float" do
      assert {:ok, 0.85} = GetReward.parse_response("0.85")
    end

    test "parse_response handles trailing text" do
      assert {:ok, 0.7} = GetReward.parse_response("0.7 (good progress)")
    end

    test "parse_response clamps values above 1.0" do
      assert {:ok, 1.0} = GetReward.parse_response("1.5")
    end

    test "parse_response clamps values below 0.0" do
      assert {:ok, +0.0} = GetReward.parse_response("-0.3")
    end

    test "parse_response rejects non-numeric" do
      assert {:error, %PromptError{reason: :invalid_float}} = GetReward.parse_response("high")
    end
  end

  describe "GetSemantic" do
    test "build_messages appends overlay to system message when provided" do
      trajectory = [%{observation: "X", action: "Y", reward: 0.5}]

      messages =
        GetSemantic.build_messages(%{
          trajectory: trajectory,
          goal: "Test",
          overlay: "Focus on API contracts."
        })

      assert [%{role: :system, content: system}, _] = messages
      assert system =~ "Focus on API contracts."
    end

    test "build_messages includes trajectory with rewards" do
      trajectory = [
        %{observation: "Database is slow", action: "Added index", reward: 0.9}
      ]

      messages = GetSemantic.build_messages(%{trajectory: trajectory, goal: "Optimize DB"})

      assert [%{role: :system, content: system}, %{role: :user, content: user}] = messages
      assert system =~ "factual knowledge"
      assert system =~ "JSON"
      assert user =~ "Reward: 0.9"
      assert user =~ "Optimize DB"
    end

    test "schema returns a Zoi schema" do
      schema = GetSemantic.schema()
      assert is_function(schema) or is_map(schema) or is_tuple(schema)
    end

    test "parse_response extracts structured facts with concepts" do
      response = %{
        facts: [
          %{
            proposition: "Adding an index improves query performance",
            concepts: ["index", "query performance", "database optimization"]
          },
          %{
            proposition: "The users table had a sequential scan bottleneck",
            concepts: ["users table", "sequential scan", "bottleneck"]
          }
        ]
      }

      assert {:ok, facts} = GetSemantic.parse_response(response)
      assert [first, second] = facts

      assert %{
               proposition: "Adding an index improves query performance",
               concepts: ["index", "query performance", "database optimization"]
             } = first

      assert %{
               proposition: "The users table had a sequential scan bottleneck",
               concepts: ["users table", "sequential scan", "bottleneck"]
             } = second
    end

    test "parse_response accepts an empty facts list" do
      assert {:ok, []} = GetSemantic.parse_response(%{facts: []})
    end

    test "parse_response rejects non-matching input" do
      assert {:error, %PromptError{reason: :no_facts_extracted}} =
               GetSemantic.parse_response(%{})
    end

    test "parse_response keeps valid source steps and dedupes them" do
      response = %{
        facts: [
          %{proposition: "Fact", concepts: ["c"], source_steps: [1, 2, 2, 1]}
        ]
      }

      assert {:ok, [%{source_steps: [1, 2]}]} = GetSemantic.parse_response(response)
    end

    test "parse_response drops invalid source steps and defaults to empty" do
      response = %{
        facts: [
          %{proposition: "Fact a", concepts: ["c"], source_steps: [0, -1, "x", 3]},
          %{proposition: "Fact b", concepts: ["c"]}
        ]
      }

      assert {:ok, [%{source_steps: [3]}, %{source_steps: []}]} =
               GetSemantic.parse_response(response)
    end
  end

  describe "GetProcedural" do
    test "build_messages appends overlay to system message when provided" do
      trajectory = [%{observation: "X", action: "Y", reward: 0.5}]

      messages =
        GetProcedural.build_messages(%{
          trajectory: trajectory,
          goal: "Test",
          overlay: "Extract only high-level patterns."
        })

      assert [%{role: :system, content: system}, _] = messages
      assert system =~ "Extract only high-level patterns."
    end

    test "build_messages includes trajectory with rewards" do
      trajectory = [
        %{observation: "Timeout error", action: "Increased timeout", reward: 0.8}
      ]

      messages = GetProcedural.build_messages(%{trajectory: trajectory, goal: "Fix timeouts"})

      assert [%{role: :system, content: system}, %{role: :user, content: user}] = messages
      assert system =~ "actionable instructions"
      assert system =~ "JSON"
      assert user =~ "Fix timeouts"
      assert user =~ "Timeout error"
    end

    test "schema returns a Zoi schema" do
      schema = GetProcedural.schema()
      assert is_function(schema) or is_map(schema) or is_tuple(schema)
    end

    test "parse_response extracts structured instructions with intents" do
      response = %{
        instructions: [
          %{
            intent: "Optimize database query performance",
            condition: "Database queries exceed 5 seconds",
            instruction: "Add an index on the queried column",
            expected_outcome: "Query time drops below 100ms"
          },
          %{
            intent: "Handle connection pool exhaustion",
            condition: "Connection pool is exhausted",
            instruction: "Increase pool size or add queuing",
            expected_outcome: "Requests stop timing out"
          }
        ]
      }

      assert {:ok, instructions} = GetProcedural.parse_response(response)
      assert [first, second] = instructions

      assert %{
               intent: "Optimize database query performance",
               condition: "Database queries exceed 5 seconds",
               instruction: "Add an index on the queried column",
               expected_outcome: "Query time drops below 100ms"
             } = first

      assert %{
               intent: "Handle connection pool exhaustion",
               condition: "Connection pool is exhausted",
               instruction: "Increase pool size or add queuing",
               expected_outcome: "Requests stop timing out"
             } = second
    end

    test "parse_response accepts empty instructions list" do
      assert {:ok, []} = GetProcedural.parse_response(%{instructions: []})
    end

    test "parse_response rejects non-list instructions" do
      for instructions <- [nil, "", %{}, 42] do
        assert {:error, %PromptError{reason: :no_instructions_extracted}} =
                 GetProcedural.parse_response(%{instructions: instructions})
      end
    end

    test "parse_response rejects non-matching input" do
      assert {:error, %PromptError{reason: :no_instructions_extracted}} =
               GetProcedural.parse_response(%{})
    end
  end

  describe "GetReturn" do
    test "build_messages appends overlay to system message when provided" do
      trajectory = [%{action: "A", observation: "O", state: nil, reward: 0.5}]

      prescriptions = [
        %{index: 0, intent: "G", instruction: "I", condition: "C", expected_outcome: "E"}
      ]

      messages =
        GetReturn.build_messages(%{
          trajectory: trajectory,
          goal: "Test",
          prescriptions: prescriptions,
          overlay: "Score conservatively."
        })

      assert [%{role: :system, content: system}, _] = messages
      assert system =~ "Score conservatively."
    end

    test "build_messages includes trajectory with observations and prescriptions with intent" do
      trajectory = [
        %{action: "Step A", observation: "Saw X", state: "state A", reward: 0.8},
        %{action: "Step B", observation: "Saw Y", state: nil, reward: 0.6}
      ]

      prescriptions = [
        %{
          index: 0,
          intent: "Goal X",
          instruction: "Do X",
          condition: "When Y",
          expected_outcome: "Z happens"
        }
      ]

      messages =
        GetReturn.build_messages(%{
          trajectory: trajectory,
          goal: "Complete task",
          prescriptions: prescriptions
        })

      assert [%{role: :system, content: system}, %{role: :user, content: user}] = messages
      assert system =~ "Score 1-10"
      assert user =~ "Complete task"
      assert user =~ "Step A"
      assert user =~ "Observation: Saw X"
      assert user =~ "Intent: Goal X"
      assert user =~ "Instruction: Do X"
    end

    test "schema returns a Zoi schema" do
      schema = GetReturn.schema()
      assert is_function(schema) or is_map(schema) or is_tuple(schema)
    end

    test "parse_response normalizes 1-10 scores to 0.0-1.0" do
      response = %{scores: [%{index: 0, return_score: 1}, %{index: 1, return_score: 10}]}
      assert {:ok, scores} = GetReturn.parse_response(response)
      assert [%{index: 0, return_score: +0.0}, %{index: 1, return_score: 1.0}] = scores
    end

    test "parse_response normalizes mid-range scores" do
      response = %{scores: [%{index: 0, return_score: 5}, %{index: 1, return_score: 8}]}
      assert {:ok, scores} = GetReturn.parse_response(response)
      assert [%{index: 0, return_score: score_5}, %{index: 1, return_score: score_8}] = scores
      assert_in_delta score_5, 0.4444, 0.001
      assert_in_delta score_8, 0.7778, 0.001
    end

    test "parse_response clamps out-of-range values" do
      response = %{scores: [%{index: 0, return_score: 15}, %{index: 1, return_score: 0}]}
      assert {:ok, scores} = GetReturn.parse_response(response)
      assert [%{return_score: 1.0}, %{return_score: +0.0}] = scores
    end

    test "parse_response rejects empty scores" do
      assert {:error, %PromptError{reason: :no_scores_extracted}} =
               GetReturn.parse_response(%{scores: []})
    end

    test "parse_response rejects non-matching input" do
      assert {:error, %PromptError{reason: :no_scores_extracted}} =
               GetReturn.parse_response(%{})
    end
  end
end
