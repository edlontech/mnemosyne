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
    test "build_messages returns system and user messages with interpolated variables" do
      messages =
        GetSubgoal.build_messages(%{
          observation: "The file exists",
          action: "Read the file",
          goal: "Extract data from logs"
        })

      assert [%{role: :system, content: system}, %{role: :user, content: user}] = messages
      assert system =~ "sub-goal"
      assert user =~ "Extract data from logs"
      assert user =~ "The file exists"
      assert user =~ "Read the file"
    end

    test "parse_response returns trimmed subgoal string" do
      assert {:ok, "Navigate to the config directory"} =
               GetSubgoal.parse_response("  Navigate to the config directory  \n")
    end

    test "parse_response rejects empty response" do
      assert {:error, %PromptError{reason: :empty_response}} = GetSubgoal.parse_response("   ")
    end
  end

  describe "GetReward" do
    test "build_messages includes subgoal, observation, and action" do
      messages =
        GetReward.build_messages(%{
          observation: "Server responded 200",
          action: "Send GET request",
          subgoal: "Verify API health"
        })

      assert [%{role: :system}, %{role: :user, content: user}] = messages
      assert user =~ "Verify API health"
      assert user =~ "Server responded 200"
      assert user =~ "Send GET request"
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
    test "build_messages formats trajectory steps" do
      trajectory = [
        %{observation: "Saw door", action: "Opened door"},
        %{observation: "Entered room", action: "Looked around"}
      ]

      messages = GetState.build_messages(%{trajectory: trajectory, goal: "Find the key"})

      assert [%{role: :system}, %{role: :user, content: user}] = messages
      assert user =~ "Step 1:"
      assert user =~ "Step 2:"
      assert user =~ "Saw door"
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
    test "build_messages includes trajectory and prescriptions" do
      trajectory = [
        %{action: "Step A", reward: 0.8},
        %{action: "Step B", reward: 0.6}
      ]

      prescriptions = [
        %{index: 0, instruction: "Do X", condition: "When Y", expected_outcome: "Z happens"}
      ]

      messages =
        GetReturn.build_messages(%{
          trajectory: trajectory,
          goal: "Complete task",
          prescriptions: prescriptions
        })

      assert [%{role: :system, content: system}, %{role: :user, content: user}] = messages
      assert system =~ "prescription quality"
      assert user =~ "2 steps"
      assert user =~ "Complete task"
      assert user =~ "[0] Instruction: Do X"
      assert user =~ "Condition: When Y"
    end

    test "schema returns a Zoi schema" do
      schema = GetReturn.schema()
      assert is_function(schema) or is_map(schema) or is_tuple(schema)
    end

    test "parse_response extracts scored prescriptions" do
      response = %{scores: [%{index: 0, return_score: 0.72}, %{index: 1, return_score: 0.9}]}
      assert {:ok, scores} = GetReturn.parse_response(response)
      assert [%{index: 0, return_score: 0.72}, %{index: 1, return_score: 0.9}] = scores
    end

    test "parse_response clamps out-of-range values" do
      response = %{scores: [%{index: 0, return_score: 2.5}, %{index: 1, return_score: -1.0}]}
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
