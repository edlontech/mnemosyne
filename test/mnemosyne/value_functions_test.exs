defmodule Mnemosyne.ValueFunctionsTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.ValueFunctions.EpisodicRelevant
  alias Mnemosyne.ValueFunctions.ProceduralEqual
  alias Mnemosyne.ValueFunctions.SemanticRelevant
  alias Mnemosyne.ValueFunctions.SourceLinked
  alias Mnemosyne.ValueFunctions.SubgoalMatch
  alias Mnemosyne.ValueFunctions.TagExact

  describe "TagExact" do
    test "passes relevance through unchanged" do
      assert TagExact.score(0.95, %{}) == 0.95
      assert TagExact.score(0.0, %{}) == 0.0
    end

    test "threshold is 0.9" do
      assert TagExact.threshold() == 0.9
    end

    test "top_k is 10" do
      assert TagExact.top_k() == 10
    end
  end

  describe "SemanticRelevant" do
    test "passes relevance through unchanged" do
      assert SemanticRelevant.score(0.5, %{}) == 0.5
    end

    test "threshold is 0.0" do
      assert SemanticRelevant.threshold() == 0.0
    end

    test "top_k is 20" do
      assert SemanticRelevant.top_k() == 20
    end
  end

  describe "ProceduralEqual" do
    test "passes relevance through unchanged" do
      assert ProceduralEqual.score(0.85, %{}) == 0.85
    end

    test "threshold is 0.8" do
      assert ProceduralEqual.threshold() == 0.8
    end

    test "top_k is 10" do
      assert ProceduralEqual.top_k() == 10
    end
  end

  describe "SubgoalMatch" do
    test "passes relevance through unchanged" do
      assert SubgoalMatch.score(0.75, %{}) == 0.75
    end

    test "threshold is 0.75" do
      assert SubgoalMatch.threshold() == 0.75
    end

    test "top_k is 10" do
      assert SubgoalMatch.top_k() == 10
    end
  end

  describe "EpisodicRelevant" do
    test "passes relevance through unchanged" do
      assert EpisodicRelevant.score(0.3, %{}) == 0.3
    end

    test "threshold is 0.0" do
      assert EpisodicRelevant.threshold() == 0.0
    end

    test "top_k is 30" do
      assert EpisodicRelevant.top_k() == 30
    end
  end

  describe "SourceLinked" do
    test "passes relevance through unchanged" do
      assert SourceLinked.score(0.1, %{}) == 0.1
    end

    test "threshold is 0.0" do
      assert SourceLinked.threshold() == 0.0
    end

    test "top_k is 50" do
      assert SourceLinked.top_k() == 50
    end
  end
end
