defmodule Mnemosyne.Pipeline.Prompts.StructuringPromptsTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Errors.Invalid.PromptError
  alias Mnemosyne.Pipeline.Prompts.GetProcedural
  alias Mnemosyne.Pipeline.Prompts.GetReturn
  alias Mnemosyne.Pipeline.Prompts.GetReward
  alias Mnemosyne.Pipeline.Prompts.GetSemantic
  alias Mnemosyne.Pipeline.Prompts.GetState
  alias Mnemosyne.Pipeline.Prompts.GetSubgoal

  describe "GetSubgoal" do
    test "build_messages includes state when provided" do
      messages =
        GetSubgoal.build_messages(%{
          observation: "The file exists",
          action: "Read the file",
          goal: "Extract data from logs",
          state: "Agent has identified the log directory"
        })

      assert [%{role: :system, content: system}, %{role: :user, content: user}] = messages
      assert system =~ "subgoal"
      assert user =~ "Extract data from logs"
      assert user =~ "The file exists"
      assert user =~ "Read the file"
      assert user =~ "Agent has identified the log directory"
    end

    test "build_messages handles nil state for initial step" do
      messages =
        GetSubgoal.build_messages(%{
          observation: "The file exists",
          action: "Read the file",
          goal: "Extract data from logs",
          state: nil
        })

      assert [%{role: :system, content: _}, %{role: :user, content: user}] = messages
      assert user =~ "initial state"
    end

    test "schema returns a valid Zoi schema with reasoning and subgoal" do
      schema = GetSubgoal.schema()
      assert {:ok, _} = Zoi.parse(schema, %{"reasoning" => "r", "subgoal" => "s"})
    end

    test "parse_response extracts subgoal from structured output" do
      assert {:ok, "Navigate to the config directory"} =
               GetSubgoal.parse_response(%{
                 "reasoning" => "analysis",
                 "subgoal" => "  Navigate to the config directory  "
               })
    end

    test "parse_response rejects empty subgoal" do
      assert {:error, %PromptError{reason: :empty_response}} =
               GetSubgoal.parse_response(%{"reasoning" => "analysis", "subgoal" => "   "})
    end

    test "parse_response rejects invalid schema" do
      assert {:error, %PromptError{reason: :invalid_schema}} =
               GetSubgoal.parse_response(%{"wrong" => "format"})
    end
  end

  describe "GetReward" do
    test "build_messages includes subgoal, observation, and action" do
      messages =
        GetReward.build_messages(%{
          observation: "Server responded 200",
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

  describe "GetState" do
    test "build_messages for first step with nil previous_state" do
      messages =
        GetState.build_messages(%{
          previous_state: nil,
          action: "Opened door",
          observation: "Saw door",
          goal: "Find the key"
        })

      assert [%{role: :system, content: system}, %{role: :user, content: user}] = messages
      assert system =~ "initial observation"
      assert user =~ "Saw door"
      assert user =~ "Opened door"
      assert user =~ "Find the key"
    end

    test "build_messages for subsequent step with previous state" do
      messages =
        GetState.build_messages(%{
          previous_state: "Agent is in a hallway",
          action: "Looked around",
          observation: "Entered room",
          goal: "Find the key"
        })

      assert [%{role: :system, content: system}, %{role: :user, content: user}] = messages
      assert system =~ "previous environment state"
      assert user =~ "Agent is in a hallway"
      assert user =~ "Looked around"
      assert user =~ "Entered room"
      assert user =~ "Find the key"
    end

    test "parse_response returns trimmed state string" do
      assert {:ok, "The agent is in a dark room."} =
               GetState.parse_response("  The agent is in a dark room.  ")
    end

    test "parse_response rejects empty response" do
      assert {:error, %PromptError{reason: :empty_response}} = GetState.parse_response("")
    end
  end

  describe "GetSemantic" do
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

    test "parse_response rejects empty facts list" do
      assert {:error, %PromptError{reason: :no_facts_extracted}} =
               GetSemantic.parse_response(%{facts: []})
    end

    test "parse_response rejects non-matching input" do
      assert {:error, %PromptError{reason: :no_facts_extracted}} =
               GetSemantic.parse_response(%{})
    end
  end

  describe "GetProcedural" do
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

    test "parse_response rejects empty instructions list" do
      assert {:error, %PromptError{reason: :no_instructions_extracted}} =
               GetProcedural.parse_response(%{instructions: []})
    end

    test "parse_response rejects non-matching input" do
      assert {:error, %PromptError{reason: :no_instructions_extracted}} =
               GetProcedural.parse_response(%{})
    end
  end

  describe "GetReturn" do
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
