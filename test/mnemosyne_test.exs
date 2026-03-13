defmodule MnemosyneTest do
  use ExUnit.Case, async: false

  import Mimic

  alias Mnemosyne.Embedding
  alias Mnemosyne.Errors.Framework.PipelineError
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.GraphBackends.Persistence.DETS
  alias Mnemosyne.LLM
  alias Mnemosyne.Pipeline.Reasoning.ReasonedMemory

  @moduletag :tmp_dir

  setup :set_mimic_global

  defp stub_llm_for_episode do
    stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
      {:ok, %LLM.Response{content: "0.5", model: "test", usage: %{}}}
    end)

    stub(Mnemosyne.MockEmbedding, :embed, fn _text, _opts ->
      {:ok, %Embedding.Response{vectors: [List.duplicate(0.1, 128)], model: "test", usage: %{}}}
    end)
  end

  defp stub_extraction_success do
    stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
      {:ok, %LLM.Response{content: "0.5", model: "test", usage: %{}}}
    end)

    stub(Mnemosyne.MockLLM, :chat_structured, fn messages, _schema, _opts ->
      system_content =
        messages
        |> Enum.find(%{content: ""}, &(&1.role == :system))
        |> Map.get(:content, "")

      content =
        cond do
          String.contains?(system_content, "factual knowledge") ->
            %{facts: [%{proposition: "some fact", concepts: ["concept1", "concept2"]}]}

          String.contains?(system_content, "actionable instructions") ->
            %{
              instructions: [
                %{
                  intent: "goal",
                  condition: "condition",
                  instruction: "action",
                  expected_outcome: "outcome"
                }
              ]
            }

          true ->
            %{}
        end

      {:ok, %LLM.Response{content: content, model: "test", usage: %{}}}
    end)

    stub(Mnemosyne.MockEmbedding, :embed, fn _text, _opts ->
      {:ok, %Embedding.Response{vectors: [List.duplicate(0.1, 128)], model: "test", usage: %{}}}
    end)

    stub(Mnemosyne.MockEmbedding, :embed_batch, fn texts, _opts ->
      vectors = Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)
      {:ok, %Embedding.Response{vectors: vectors, model: "test", usage: %{}}}
    end)
  end

  defp stub_recall_success do
    stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
      {:ok, %LLM.Response{content: "semantic", model: "test", usage: %{}}}
    end)

    stub(Mnemosyne.MockEmbedding, :embed, fn _text, _opts ->
      {:ok, %Embedding.Response{vectors: [List.duplicate(0.1, 128)], model: "test", usage: %{}}}
    end)

    stub(Mnemosyne.MockEmbedding, :embed_batch, fn texts, _opts ->
      vectors = Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)
      {:ok, %Embedding.Response{vectors: vectors, model: "test", usage: %{}}}
    end)
  end

  defp build_config do
    {:ok, config} =
      Zoi.parse(Mnemosyne.Config.t(), %{
        llm: %{model: "test-model", opts: %{}},
        embedding: %{model: "test-embed", opts: %{}}
      })

    config
  end

  defp start_supervisor(tmp_dir) do
    dets_path = Path.join(tmp_dir, "mnemosyne_test.dets")
    persistence = {DETS, path: dets_path}

    opts = [
      backend: {InMemory, persistence: persistence},
      config: build_config(),
      llm: Mnemosyne.MockLLM,
      embedding: Mnemosyne.MockEmbedding
    ]

    start_supervised!({Mnemosyne.Supervisor, opts})
  end

  describe "start_session/2" do
    test "returns {:ok, session_id} with valid string ID", %{tmp_dir: tmp_dir} do
      start_supervisor(tmp_dir)

      assert {:ok, session_id} = Mnemosyne.start_session("test goal")
      assert is_binary(session_id)
      assert String.starts_with?(session_id, "session_")
    end
  end

  describe "session_state/1" do
    test "returns current state of a session", %{tmp_dir: tmp_dir} do
      start_supervisor(tmp_dir)

      {:ok, session_id} = Mnemosyne.start_session("test goal")
      assert :collecting = Mnemosyne.session_state(session_id)
    end
  end

  describe "full write path" do
    test "start_session -> append -> close_and_commit produces graph nodes", %{tmp_dir: tmp_dir} do
      stub_extraction_success()
      start_supervisor(tmp_dir)

      {:ok, session_id} = Mnemosyne.start_session("test goal")
      assert :ok = Mnemosyne.append(session_id, "saw something", "did something")
      assert :ok = Mnemosyne.close_and_commit(session_id)

      graph = Mnemosyne.get_graph()
      assert map_size(graph.nodes) > 0
    end
  end

  describe "recall/2" do
    test "returns {:ok, %ReasonedMemory{}}", %{tmp_dir: tmp_dir} do
      stub_recall_success()
      start_supervisor(tmp_dir)

      node = %Semantic{
        id: "s1",
        proposition: "Elixir is functional",
        confidence: 0.9
      }

      changeset = Changeset.add_node(Changeset.new(), node)
      :ok = Mnemosyne.apply_changeset(changeset)

      assert {:ok, %ReasonedMemory{}} =
               Mnemosyne.recall("what is elixir?")
    end
  end

  describe "close_and_commit retries" do
    test "retries on transient failure then succeeds", %{tmp_dir: tmp_dir} do
      chat_count = :counters.new(1, [:atomics])
      structured_count = :counters.new(1, [:atomics])

      stub(Mnemosyne.MockLLM, :chat, fn messages, _opts ->
        count = :counters.get(chat_count, 1)
        :counters.add(chat_count, 1, 1)

        system_content =
          messages
          |> Enum.find(%{content: ""}, &(&1.role == :system))
          |> Map.get(:content, "")

        if String.contains?(system_content, "return") and count < 2 do
          {:error, :transient_failure}
        else
          {:ok, %LLM.Response{content: "0.5", model: "test", usage: %{}}}
        end
      end)

      stub(Mnemosyne.MockLLM, :chat_structured, fn messages, _schema, _opts ->
        count = :counters.get(structured_count, 1)
        :counters.add(structured_count, 1, 1)

        system_content =
          messages
          |> Enum.find(%{content: ""}, &(&1.role == :system))
          |> Map.get(:content, "")

        if count < 4 do
          {:error, :transient_failure}
        else
          cond do
            String.contains?(system_content, "factual knowledge") ->
              {:ok,
               %LLM.Response{
                 content: %{facts: [%{proposition: "a fact", concepts: ["c1", "c2"]}]},
                 model: "test",
                 usage: %{}
               }}

            String.contains?(system_content, "actionable instructions") ->
              {:ok,
               %LLM.Response{
                 content: %{
                   instructions: [
                     %{intent: "goal", condition: "c", instruction: "a", expected_outcome: "o"}
                   ]
                 },
                 model: "test",
                 usage: %{}
               }}

            true ->
              {:ok, %LLM.Response{content: %{}, model: "test", usage: %{}}}
          end
        end
      end)

      stub(Mnemosyne.MockEmbedding, :embed, fn _text, _opts ->
        {:ok, %Embedding.Response{vectors: [List.duplicate(0.1, 128)], model: "test", usage: %{}}}
      end)

      stub(Mnemosyne.MockEmbedding, :embed_batch, fn texts, _opts ->
        vectors = Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)
        {:ok, %Embedding.Response{vectors: vectors, model: "test", usage: %{}}}
      end)

      start_supervisor(tmp_dir)

      {:ok, session_id} = Mnemosyne.start_session("test goal")
      :ok = Mnemosyne.append(session_id, "saw something", "did something")
      assert :ok = Mnemosyne.close_and_commit(session_id, max_retries: 2)
    end

    test "returns error after max retries exhausted", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      start_supervisor(tmp_dir)

      {:ok, session_id} = Mnemosyne.start_session("test goal")
      :ok = Mnemosyne.append(session_id, "saw something", "did something")

      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        {:error, :permanent_failure}
      end)

      stub(Mnemosyne.MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        {:error, :permanent_failure}
      end)

      stub(Mnemosyne.MockEmbedding, :embed_batch, fn texts, _opts ->
        vectors = Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)
        {:ok, %Embedding.Response{vectors: vectors, model: "test", usage: %{}}}
      end)

      assert {:error, %PipelineError{reason: :extraction_failed}} =
               Mnemosyne.close_and_commit(session_id, max_retries: 1)
    end
  end

  describe "recall_in_context/3" do
    test "augments query with session context and returns ReasonedMemory", %{tmp_dir: tmp_dir} do
      stub_llm_for_episode()
      start_supervisor(tmp_dir)

      node = %Semantic{
        id: "ctx-1",
        proposition: "Elixir uses pattern matching",
        confidence: 0.9
      }

      changeset = Changeset.add_node(Changeset.new(), node)
      :ok = Mnemosyne.apply_changeset(changeset)

      {:ok, session_id} = Mnemosyne.start_session("learn elixir")
      :ok = Mnemosyne.append(session_id, "read about pattern matching", "took notes")

      queries_seen = :ets.new(:queries_seen, [:set, :public])

      stub(Mnemosyne.MockEmbedding, :embed, fn text, _opts ->
        :ets.insert(queries_seen, {:query, text})
        {:ok, %Embedding.Response{vectors: [List.duplicate(0.1, 128)], model: "test", usage: %{}}}
      end)

      stub(Mnemosyne.MockEmbedding, :embed_batch, fn texts, _opts ->
        vectors = Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)
        {:ok, %Embedding.Response{vectors: vectors, model: "test", usage: %{}}}
      end)

      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        {:ok, %LLM.Response{content: "semantic", model: "test", usage: %{}}}
      end)

      assert {:ok, %ReasonedMemory{}} =
               Mnemosyne.recall_in_context(session_id, "what is pattern matching?")

      [{:query, augmented_query}] = :ets.lookup(queries_seen, :query)
      assert augmented_query =~ "learn elixir"
      assert augmented_query =~ "read about pattern matching"
      assert augmented_query =~ "what is pattern matching?"
    end
  end

  describe "close_and_commit timeout" do
    test "returns {:error, %PipelineError{reason: :extraction_timeout}} when extraction never settles",
         %{
           tmp_dir: tmp_dir
         } do
      stub_llm_for_episode()
      start_supervisor(tmp_dir)

      {:ok, session_id} = Mnemosyne.start_session("test goal")
      :ok = Mnemosyne.append(session_id, "saw something", "did something")

      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        Process.sleep(:timer.seconds(30))
        {:ok, %LLM.Response{content: "0.5", model: "test", usage: %{}}}
      end)

      stub(Mnemosyne.MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        Process.sleep(:timer.seconds(30))
        {:ok, %LLM.Response{content: %{}, model: "test", usage: %{}}}
      end)

      assert {:error, %PipelineError{reason: :extraction_timeout}} =
               Mnemosyne.close_and_commit(session_id,
                 max_retries: 0,
                 max_polls: 3,
                 poll_interval: 10
               )
    end
  end

  describe "management" do
    test "apply_changeset adds nodes to graph", %{tmp_dir: tmp_dir} do
      start_supervisor(tmp_dir)

      node = %Semantic{
        id: "mgmt-1",
        proposition: "Test fact",
        confidence: 0.9
      }

      changeset = Changeset.add_node(Changeset.new(), node)
      assert :ok = Mnemosyne.apply_changeset(changeset)

      graph = Mnemosyne.get_graph()
      assert graph.nodes["mgmt-1"] != nil
    end

    test "delete_nodes removes nodes from graph", %{tmp_dir: tmp_dir} do
      start_supervisor(tmp_dir)

      node = %Semantic{
        id: "del-1",
        proposition: "To delete",
        confidence: 0.9
      }

      changeset = Changeset.add_node(Changeset.new(), node)
      :ok = Mnemosyne.apply_changeset(changeset)

      assert :ok = Mnemosyne.delete_nodes(["del-1"])
      graph = Mnemosyne.get_graph()
      assert graph.nodes["del-1"] == nil
    end
  end
end
