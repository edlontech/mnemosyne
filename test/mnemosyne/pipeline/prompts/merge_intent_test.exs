defmodule Mnemosyne.Pipeline.Prompts.MergeIntentTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Errors.Invalid.PromptError
  alias Mnemosyne.Pipeline.Prompts.MergeIntent

  describe "build_messages/1" do
    test "appends overlay to system message when provided" do
      messages =
        MergeIntent.build_messages(%{
          existing_intent: "Optimize queries",
          new_intent: "Improve performance",
          overlay: "Keep intent generic."
        })

      assert [%{role: :system, content: system}, _] = messages
      assert system =~ "Keep intent generic."
    end

    test "includes both intent descriptions in messages" do
      messages =
        MergeIntent.build_messages(%{
          existing_intent: "Optimize database queries",
          new_intent: "Improve query performance"
        })

      assert [%{role: :system, content: system}, %{role: :user, content: user}] = messages
      assert system =~ "merge"
      assert user =~ "Optimize database queries"
      assert user =~ "Improve query performance"
    end
  end

  describe "schema/0" do
    test "validates and coerces a valid input" do
      schema = MergeIntent.schema()

      assert {:ok, %{merged_intent: "consolidated goal"}} =
               Zoi.parse(schema, %{"merged_intent" => "consolidated goal"})
    end
  end

  describe "parse_response/1" do
    test "extracts merged intent string" do
      assert {:ok, "Optimize database query performance"} =
               MergeIntent.parse_response(%{merged_intent: "Optimize database query performance"})
    end

    test "trims whitespace from merged intent" do
      assert {:ok, "Optimize queries"} =
               MergeIntent.parse_response(%{merged_intent: "  Optimize queries  \n"})
    end

    test "rejects empty string" do
      assert {:error, %PromptError{reason: :invalid_merge_result}} =
               MergeIntent.parse_response(%{merged_intent: "   "})
    end

    test "rejects missing field" do
      assert {:error, %PromptError{reason: :invalid_merge_result}} =
               MergeIntent.parse_response(%{})
    end

    test "rejects non-string value" do
      assert {:error, %PromptError{reason: :invalid_merge_result}} =
               MergeIntent.parse_response(%{merged_intent: 42})
    end
  end
end
