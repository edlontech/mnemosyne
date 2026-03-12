defmodule Mnemosyne.Pipeline.Prompts.StructuringPromptsTest do
  use ExUnit.Case, async: true

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
      assert {:error, :empty_response} = GetSubgoal.parse_response("   ")
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
      assert {:error, :invalid_float} = GetReward.parse_response("high")
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
      assert {:error, :empty_response} = GetState.parse_response("")
    end
  end

  describe "GetSemantic" do
    test "build_messages includes trajectory with rewards" do
      trajectory = [
        %{observation: "Database is slow", action: "Added index", reward: 0.9}
      ]

      messages = GetSemantic.build_messages(%{trajectory: trajectory, goal: "Optimize DB"})

      assert [%{role: :system}, %{role: :user, content: user}] = messages
      assert user =~ "Reward: 0.9"
      assert user =~ "Optimize DB"
    end

    test "parse_response splits lines into facts" do
      response = """
      Adding an index improves query performance
      The users table had a sequential scan bottleneck
      """

      assert {:ok, facts} = GetSemantic.parse_response(response)

      assert [
               "Adding an index improves query performance",
               "The users table had a sequential scan bottleneck"
             ] = facts
    end

    test "parse_response skips blank lines" do
      assert {:ok, ["Fact one", "Fact two"]} =
               GetSemantic.parse_response("Fact one\n\n\nFact two\n")
    end

    test "parse_response rejects empty response" do
      assert {:error, :no_facts_extracted} = GetSemantic.parse_response("   \n  \n  ")
    end
  end

  describe "GetProcedural" do
    test "build_messages includes trajectory with rewards" do
      trajectory = [
        %{observation: "Timeout error", action: "Increased timeout", reward: 0.8}
      ]

      messages = GetProcedural.build_messages(%{trajectory: trajectory, goal: "Fix timeouts"})

      assert [%{role: :system}, %{role: :user, content: user}] = messages
      assert user =~ "Fix timeouts"
      assert user =~ "Timeout error"
    end

    test "parse_response extracts structured instructions" do
      response = """
      WHEN: Database queries exceed 5 seconds
      DO: Add an index on the queried column
      EXPECT: Query time drops below 100ms

      WHEN: Connection pool is exhausted
      DO: Increase pool size or add queuing
      EXPECT: Requests stop timing out
      """

      assert {:ok, instructions} = GetProcedural.parse_response(response)
      assert [first, second] = instructions

      assert %{
               condition: "Database queries exceed 5 seconds",
               instruction: "Add an index on the queried column",
               expected_outcome: "Query time drops below 100ms"
             } = first

      assert %{
               condition: "Connection pool is exhausted",
               instruction: "Increase pool size or add queuing",
               expected_outcome: "Requests stop timing out"
             } = second
    end

    test "parse_response skips malformed blocks" do
      response = """
      WHEN: Valid condition
      DO: Valid instruction
      EXPECT: Valid outcome

      This is not a valid block at all
      """

      assert {:ok, [instruction]} = GetProcedural.parse_response(response)
      assert instruction.condition == "Valid condition"
    end

    test "parse_response rejects response with no valid instructions" do
      assert {:error, :no_instructions_extracted} =
               GetProcedural.parse_response("Just some random text")
    end
  end

  describe "GetReturn" do
    test "build_messages includes trajectory stats" do
      trajectory = [
        %{action: "Step A", reward: 0.8},
        %{action: "Step B", reward: 0.6}
      ]

      messages = GetReturn.build_messages(%{trajectory: trajectory, goal: "Complete task"})

      assert [%{role: :system}, %{role: :user, content: user}] = messages
      assert user =~ "2 steps"
      assert user =~ "avg reward: 0.7"
      assert user =~ "Complete task"
    end

    test "build_messages handles empty trajectory" do
      messages = GetReturn.build_messages(%{trajectory: [], goal: "Goal"})
      assert [_, %{role: :user, content: user}] = messages
      assert user =~ "0 steps"
      assert user =~ "avg reward: 0.0"
    end

    test "parse_response extracts valid float" do
      assert {:ok, 0.72} = GetReturn.parse_response("0.72")
    end

    test "parse_response clamps out-of-range values" do
      assert {:ok, 1.0} = GetReturn.parse_response("2.5")
      assert {:ok, +0.0} = GetReturn.parse_response("-1.0")
    end

    test "parse_response rejects non-numeric" do
      assert {:error, :invalid_float} = GetReturn.parse_response("excellent")
    end
  end
end
