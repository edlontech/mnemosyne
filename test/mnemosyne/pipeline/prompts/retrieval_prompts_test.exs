defmodule Mnemosyne.Pipeline.Prompts.RetrievalPromptsTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Errors.Invalid.PromptError
  alias Mnemosyne.Pipeline.Prompts.GetMode
  alias Mnemosyne.Pipeline.Prompts.GetPlan
  alias Mnemosyne.Pipeline.Prompts.ReasonEpisodic
  alias Mnemosyne.Pipeline.Prompts.ReasonProcedural
  alias Mnemosyne.Pipeline.Prompts.ReasonSemantic

  describe "GetMode" do
    test "build_messages appends overlay to system message when provided" do
      messages = GetMode.build_messages(%{query: "Test?", overlay: "Prefer episodic."})
      assert [%{role: :system, content: system}, _] = messages
      assert system =~ "Prefer episodic."
    end

    test "build_messages returns system and user messages with query" do
      messages = GetMode.build_messages(%{query: "What happened last Tuesday?"})

      assert [%{role: :system, content: system}, %{role: :user, content: user}] = messages
      assert system =~ "episodic"
      assert system =~ "semantic"
      assert system =~ "procedural"
      assert system =~ "mixed"
      assert user =~ "What happened last Tuesday?"
    end

    test "parse_response parses valid modes" do
      assert {:ok, :episodic} = GetMode.parse_response("episodic")
      assert {:ok, :semantic} = GetMode.parse_response("semantic")
      assert {:ok, :procedural} = GetMode.parse_response("procedural")
      assert {:ok, :mixed} = GetMode.parse_response("mixed")
    end

    test "parse_response handles whitespace and casing" do
      assert {:ok, :episodic} = GetMode.parse_response("  Episodic  \n")
      assert {:ok, :semantic} = GetMode.parse_response("SEMANTIC")
    end

    test "parse_response rejects invalid modes" do
      assert {:error, %PromptError{reason: :invalid_mode}} = GetMode.parse_response("narrative")
      assert {:error, %PromptError{reason: :invalid_mode}} = GetMode.parse_response("")
    end
  end

  describe "GetPlan" do
    test "build_messages appends overlay to system message when provided" do
      messages =
        GetPlan.build_messages(%{query: "Test?", mode: :semantic, overlay: "Use broad tags."})

      assert [%{role: :system, content: system}, _] = messages
      assert system =~ "Use broad tags."
    end

    test "build_messages includes query and mode" do
      messages = GetPlan.build_messages(%{query: "How do I deploy?", mode: :procedural})

      assert [%{role: :system}, %{role: :user, content: user}] = messages
      assert user =~ "How do I deploy?"
      assert user =~ "procedural"
    end

    test "parse_response splits lines into tags" do
      response = """
      deployment
      CI/CD pipeline
      production environment
      """

      assert {:ok, tags} = GetPlan.parse_response(response)
      assert ["deployment", "CI/CD pipeline", "production environment"] = tags
    end

    test "parse_response skips blank lines" do
      assert {:ok, ["tag one", "tag two"]} =
               GetPlan.parse_response("tag one\n\n\ntag two\n")
    end

    test "parse_response rejects empty response" do
      assert {:error, %PromptError{reason: :no_tags_generated}} =
               GetPlan.parse_response("   \n  \n  ")
    end
  end

  describe "ReasonEpisodic" do
    test "build_messages appends overlay to system message when provided" do
      now = DateTime.utc_now()

      nodes = [
        %{observation: "X", action: "Y", state: "S", reward: 0.5, created_at: now}
      ]

      messages =
        ReasonEpisodic.build_messages(%{
          query: "Test?",
          nodes: nodes,
          overlay: "Focus on failures."
        })

      assert [%{role: :system, content: system}, _] = messages
      assert system =~ "Focus on failures."
    end

    test "build_messages formats episodic nodes" do
      now = DateTime.utc_now()

      nodes = [
        %{
          observation: "Server crashed",
          action: "Restarted service",
          state: "Degraded",
          reward: 0.3,
          created_at: now
        },
        %{
          observation: "Service recovered",
          action: "Verified health",
          state: "Healthy",
          reward: 0.9,
          created_at: now
        }
      ]

      messages =
        ReasonEpisodic.build_messages(%{query: "What happened during the outage?", nodes: nodes})

      assert [%{role: :system}, %{role: :user, content: user}] = messages
      assert user =~ "Episode 1"
      assert user =~ "Episode 2"
      assert user =~ "Server crashed"
      assert user =~ "What happened during the outage?"
    end

    test "parse_response extracts information from structured response" do
      assert {:ok, "The server crashed and was restarted."} =
               ReasonEpisodic.parse_response(%{
                 reasoning: "The crash is relevant.",
                 information: "The server crashed and was restarted."
               })
    end

    test "parse_response rejects empty information" do
      assert {:error, %PromptError{reason: :empty_response}} =
               ReasonEpisodic.parse_response(%{reasoning: "analysis", information: "   "})
    end

    test "parse_response rejects missing information" do
      assert {:error, %PromptError{reason: :empty_response}} =
               ReasonEpisodic.parse_response(%{})
    end
  end

  describe "ReasonSemantic" do
    test "build_messages appends overlay to system message when provided" do
      now = DateTime.utc_now()
      nodes = [%{proposition: "Fact", confidence: 0.9, created_at: now}]

      messages =
        ReasonSemantic.build_messages(%{
          query: "Test?",
          nodes: nodes,
          overlay: "Be precise."
        })

      assert [%{role: :system, content: system}, _] = messages
      assert system =~ "Be precise."
    end

    test "build_messages formats semantic nodes with confidence" do
      now = DateTime.utc_now()

      nodes = [
        %{proposition: "Elixir runs on the BEAM VM", confidence: 0.95, created_at: now},
        %{proposition: "GenServers handle synchronous calls", confidence: 0.88, created_at: now}
      ]

      messages =
        ReasonSemantic.build_messages(%{query: "Tell me about Elixir runtime", nodes: nodes})

      assert [%{role: :system}, %{role: :user, content: user}] = messages
      assert user =~ "Fact 1"
      assert user =~ "confidence: 0.95"
      assert user =~ "Elixir runs on the BEAM VM"
      assert user =~ "Tell me about Elixir runtime"
    end

    test "parse_response extracts information from structured response" do
      assert {:ok, "Elixir leverages the BEAM VM for concurrency."} =
               ReasonSemantic.parse_response(%{
                 reasoning: "The BEAM fact is high confidence.",
                 information: "Elixir leverages the BEAM VM for concurrency."
               })
    end

    test "parse_response rejects empty information" do
      assert {:error, %PromptError{reason: :empty_response}} =
               ReasonSemantic.parse_response(%{reasoning: "analysis", information: ""})
    end
  end

  describe "ReasonProcedural" do
    test "build_messages appends overlay to system message when provided" do
      now = DateTime.utc_now()

      nodes = [
        %{
          condition: "C",
          instruction: "I",
          expected_outcome: "E",
          return_score: 0.8,
          created_at: now
        }
      ]

      messages =
        ReasonProcedural.build_messages(%{
          query: "Test?",
          nodes: nodes,
          overlay: "Prefer proven procedures."
        })

      assert [%{role: :system, content: system}, _] = messages
      assert system =~ "Prefer proven procedures."
    end

    test "build_messages formats procedural nodes" do
      now = DateTime.utc_now()

      nodes = [
        %{
          condition: "deploying to prod",
          instruction: "run migrations first",
          expected_outcome: "schema is updated",
          return_score: 0.9,
          created_at: now
        },
        %{
          condition: "high traffic",
          instruction: "enable rate limiting",
          expected_outcome: "system stays stable",
          return_score: nil,
          created_at: now
        }
      ]

      messages =
        ReasonProcedural.build_messages(%{query: "How do I deploy safely?", nodes: nodes})

      assert [%{role: :system}, %{role: :user, content: user}] = messages
      assert user =~ "Procedure 1"
      assert user =~ "WHEN deploying to prod"
      assert user =~ "DO run migrations first"
      assert user =~ "How do I deploy safely?"
      assert user =~ "return: 0.90"
      assert user =~ "return: N/A"
    end

    test "parse_response extracts information from structured response" do
      assert {:ok, "First run migrations, then deploy the new code."} =
               ReasonProcedural.parse_response(%{
                 reasoning: "Migration procedure has high return.",
                 information: "First run migrations, then deploy the new code."
               })
    end

    test "parse_response rejects empty information" do
      assert {:error, %PromptError{reason: :empty_response}} =
               ReasonProcedural.parse_response(%{reasoning: "analysis", information: "   "})
    end
  end
end
