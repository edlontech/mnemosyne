defmodule Mnemosyne.Pipeline.Prompts.MergeSemanticTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Errors.Invalid.PromptError
  alias Mnemosyne.Pipeline.Prompts.MergeSemantic

  describe "build_messages/1" do
    test "presents earlier and later information in order" do
      messages =
        MergeSemantic.build_messages(%{
          earlier: "User adopted a dog in May",
          later: "User's dog is named Rex"
        })

      assert [%{role: :system, content: system}, %{role: :user, content: user}] = messages
      assert system =~ "UPDATE_SAME_FACT"
      assert system =~ "SAME_TOPIC_MERGE_WELL"
      assert system =~ "WEAK_RELATED_STITCH_RISK"
      assert user =~ "Information 1 (Earlier Information): User adopted a dog in May"
      assert user =~ "Information 2 (Later Information): User's dog is named Rex"
    end

    test "appends overlay to system message when provided" do
      messages =
        MergeSemantic.build_messages(%{earlier: "a", later: "b", overlay: "Be conservative."})

      assert [%{role: :system, content: system}, _] = messages
      assert system =~ "Be conservative."
    end
  end

  describe "parse_response/1" do
    test "returns merge for same-fact updates" do
      assert {:ok, {:merge, "merged"}} =
               MergeSemantic.parse_response(%{
                 merged_statement: "merged",
                 relationship: "UPDATE_SAME_FACT"
               })
    end

    test "returns merge for well-merging topics" do
      assert {:ok, {:merge, "merged"}} =
               MergeSemantic.parse_response(%{
                 merged_statement: "merged",
                 relationship: "SAME_TOPIC_MERGE_WELL"
               })
    end

    test "returns keep_both for weakly related pairs" do
      assert {:ok, :keep_both} =
               MergeSemantic.parse_response(%{
                 merged_statement: "stitched",
                 relationship: "WEAK_RELATED_STITCH_RISK"
               })
    end

    test "rejects unknown relationships" do
      assert {:error, %PromptError{reason: :invalid_relationship}} =
               MergeSemantic.parse_response(%{merged_statement: "m", relationship: "OTHER"})
    end

    test "rejects merges with an empty statement" do
      assert {:error, %PromptError{reason: :invalid_relationship}} =
               MergeSemantic.parse_response(%{
                 merged_statement: "",
                 relationship: "UPDATE_SAME_FACT"
               })
    end

    test "rejects malformed decisions" do
      assert {:error, %PromptError{reason: :invalid_decision}} =
               MergeSemantic.parse_response(%{tags: []})
    end
  end
end
