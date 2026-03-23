defmodule Mnemosyne.Pipeline.ReasoningTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Mnemosyne.Config
  alias Mnemosyne.Graph.Node.Episodic
  alias Mnemosyne.Graph.Node.Procedural
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.LLM
  alias Mnemosyne.Pipeline.Reasoning
  alias Mnemosyne.Pipeline.Retrieval

  setup :set_mimic_from_context

  @query "How do I deploy safely?"

  defp build_retrieval_result(candidate_map) do
    %Retrieval.Result{
      mode: :mixed,
      tags: ["deployment"],
      candidates: candidate_map
    }
  end

  defp make_episodic_candidates do
    [
      {%Episodic{
         id: "ep_1",
         observation: "Server crashed",
         action: "Restarted",
         state: "Degraded",
         subgoal: "restore service",
         reward: 0.3,
         trajectory_id: "t1"
       }, 0.9}
    ]
  end

  defp make_semantic_candidates do
    [
      {%Semantic{id: "sem_1", proposition: "Always run migrations", confidence: 0.95}, 0.85}
    ]
  end

  defp make_procedural_candidates do
    [
      {%Procedural{
         id: "proc_1",
         instruction: "Run migrations first",
         condition: "deploying to prod",
         expected_outcome: "schema updated",
         return_score: 0.9
       }, 0.88}
    ]
  end

  defp stub_reasoning_llm do
    Mnemosyne.MockLLM
    |> stub(:chat_structured, fn messages, _schema, _opts ->
      system_content =
        messages
        |> Enum.find(%{content: ""}, &(&1.role == :system))
        |> Map.get(:content)

      content =
        cond do
          system_content =~ "episodic memories" ->
            %{
              reasoning: "The crash event is directly relevant.",
              information: "The server crashed and was restarted."
            }

          system_content =~ "factual knowledge" ->
            %{
              reasoning: "Migration fact is high confidence.",
              information: "Migrations should always run before deploy."
            }

          system_content =~ "procedural knowledge" ->
            %{
              reasoning: "The migration procedure has high return.",
              information: "Run migrations first when deploying."
            }

          true ->
            %{reasoning: "analysis", information: "default summary"}
        end

      {:ok, %LLM.Response{content: content, model: "mock:test", usage: %{}}}
    end)
  end

  defp default_opts do
    [llm: Mnemosyne.MockLLM, query: @query]
  end

  describe "reason/2" do
    test "produces all three summaries when all types present" do
      stub_reasoning_llm()

      result =
        build_retrieval_result(%{
          episodic: make_episodic_candidates(),
          semantic: make_semantic_candidates(),
          procedural: make_procedural_candidates()
        })

      assert {:ok, %Reasoning.ReasonedMemory{} = memory} =
               Reasoning.reason(result, default_opts())

      assert memory.episodic == "The server crashed and was restarted."
      assert memory.semantic == "Migrations should always run before deploy."
      assert memory.procedural == "Run migrations first when deploying."
    end

    test "skips empty types and leaves them nil" do
      stub_reasoning_llm()

      result = build_retrieval_result(%{semantic: make_semantic_candidates()})

      assert {:ok, %Reasoning.ReasonedMemory{} = memory} =
               Reasoning.reason(result, default_opts())

      assert memory.semantic == "Migrations should always run before deploy."
      assert is_nil(memory.episodic)
      assert is_nil(memory.procedural)
    end

    test "returns empty ReasonedMemory when no candidates" do
      result = build_retrieval_result(%{})

      assert {:ok, %Reasoning.ReasonedMemory{} = memory} =
               Reasoning.reason(result, default_opts())

      assert is_nil(memory.episodic)
      assert is_nil(memory.semantic)
      assert is_nil(memory.procedural)
    end

    test "propagates LLM errors" do
      Mnemosyne.MockLLM
      |> stub(:chat_structured, fn _messages, _schema, _opts -> {:error, :llm_unavailable} end)

      result = build_retrieval_result(%{semantic: make_semantic_candidates()})

      assert {:error, :llm_unavailable} = Reasoning.reason(result, default_opts())
    end

    test "accepts config for per-step model overrides" do
      config = %Config{
        llm: %{model: "test:model", opts: %{}},
        embedding: %{model: "test:embed", opts: %{}},
        overrides: %{reason_semantic: %{model: "test:reasoning", opts: %{}}}
      }

      Mnemosyne.MockLLM
      |> stub(:chat_structured, fn _messages, _schema, opts ->
        assert Keyword.get(opts, :model) == "test:reasoning"

        {:ok,
         %LLM.Response{
           content: %{reasoning: "analysis", information: "Summary."},
           model: "mock:test",
           usage: %{}
         }}
      end)

      result = build_retrieval_result(%{semantic: make_semantic_candidates()})
      opts = default_opts() ++ [config: config]

      assert {:ok, %Reasoning.ReasonedMemory{semantic: "Summary."}} =
               Reasoning.reason(result, opts)
    end

    test "handles only episodic candidates" do
      stub_reasoning_llm()
      result = build_retrieval_result(%{episodic: make_episodic_candidates()})

      assert {:ok, %Reasoning.ReasonedMemory{} = memory} =
               Reasoning.reason(result, default_opts())

      assert memory.episodic == "The server crashed and was restarted."
      assert is_nil(memory.semantic)
      assert is_nil(memory.procedural)
    end

    test "handles only procedural candidates" do
      stub_reasoning_llm()
      result = build_retrieval_result(%{procedural: make_procedural_candidates()})

      assert {:ok, %Reasoning.ReasonedMemory{} = memory} =
               Reasoning.reason(result, default_opts())

      assert memory.procedural == "Run migrations first when deploying."
      assert is_nil(memory.episodic)
      assert is_nil(memory.semantic)
    end

    test "rejects empty information field" do
      Mnemosyne.MockLLM
      |> stub(:chat_structured, fn _messages, _schema, _opts ->
        {:ok,
         %LLM.Response{
           content: %{reasoning: "analysis", information: ""},
           model: "mock:test",
           usage: %{}
         }}
      end)

      result = build_retrieval_result(%{episodic: make_episodic_candidates()})

      assert {:error, _} = Reasoning.reason(result, default_opts())
    end
  end
end
