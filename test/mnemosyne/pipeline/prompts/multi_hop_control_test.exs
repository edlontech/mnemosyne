defmodule Mnemosyne.Pipeline.Prompts.MultiHopControlTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Errors.Invalid.PromptError
  alias Mnemosyne.Pipeline.Prompts.MultiHopControl

  describe "build_messages/1" do
    test "includes the query and indexed candidates" do
      messages =
        MultiHopControl.build_messages(%{
          query: "Who directed the film?",
          candidates: [
            %{index: 0, type: :semantic, content: "The film was released in 1999"},
            %{index: 1, type: :procedural, content: "Search by director name"}
          ],
          max_focus: 2
        })

      assert [%{role: :system, content: system}, %{role: :user, content: user}] = messages
      assert system =~ "retrieval controller"
      assert system =~ "at most 2"
      assert user =~ "Who directed the film?"
      assert user =~ "[0] (semantic) The film was released in 1999"
      assert user =~ "[1] (procedural) Search by director name"
    end

    test "appends overlay to system message when provided" do
      messages =
        MultiHopControl.build_messages(%{
          query: "q",
          candidates: [],
          max_focus: 2,
          overlay: "Prefer stopping early."
        })

      assert [%{role: :system, content: system}, _] = messages
      assert system =~ "Prefer stopping early."
    end
  end

  describe "parse_response/1" do
    test "parses a stop decision and clears indices" do
      assert {:ok, %{enough: true, top_indices: []}} =
               MultiHopControl.parse_response(%{enough: true, top_indices: [1, 2]})
    end

    test "parses a continue decision with focus indices" do
      assert {:ok, %{enough: false, top_indices: [2, 0]}} =
               MultiHopControl.parse_response(%{enough: false, top_indices: [2, 0]})
    end

    test "filters non-integer indices" do
      assert {:ok, %{enough: false, top_indices: [1]}} =
               MultiHopControl.parse_response(%{enough: false, top_indices: ["a", 1, nil]})
    end

    test "rejects malformed decisions" do
      assert {:error, %PromptError{reason: :invalid_decision}} =
               MultiHopControl.parse_response(%{summary: "unrelated"})

      assert {:error, %PromptError{reason: :invalid_decision}} =
               MultiHopControl.parse_response(%{enough: "yes", top_indices: []})
    end
  end
end
