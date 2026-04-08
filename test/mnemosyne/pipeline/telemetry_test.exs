defmodule Mnemosyne.Pipeline.TelemetryTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Mnemosyne.Embedding
  alias Mnemosyne.Errors.Invalid.EpisodeError
  alias Mnemosyne.Graph
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.LLM
  alias Mnemosyne.Pipeline.Episode
  alias Mnemosyne.Pipeline.Reasoning
  alias Mnemosyne.Pipeline.Retrieval
  alias Mnemosyne.Pipeline.Retrieval.TaggedCandidate
  alias Mnemosyne.Pipeline.Structuring
  alias Mnemosyne.ValueFunction

  setup :set_mimic_global

  @default_opts [llm: Mnemosyne.MockLLM, embedding: Mnemosyne.MockEmbedding]
  @test_vector List.duplicate(0.1, 128)

  defp attach_telemetry(event_name, test_pid \\ self()) do
    handler_id = "test-#{inspect(event_name)}-#{System.unique_integer()}"

    :telemetry.attach(
      handler_id,
      event_name,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp stub_append_cycle do
    Mnemosyne.MockLLM
    |> stub(:chat, fn _messages, _opts ->
      {:ok, %LLM.Response{content: "0.8", model: "mock:test", usage: %{}}}
    end)
    |> stub(:chat_structured, fn _messages, _schema, _opts ->
      {:ok,
       %LLM.Response{
         content: %{"reasoning" => "analysis", "subgoal" => "test subgoal"},
         model: "mock:test",
         usage: %{}
       }}
    end)

    Mnemosyne.MockEmbedding
    |> stub(:embed, fn _text, _opts ->
      {:ok, %Embedding.Response{vectors: [@test_vector], model: "mock:embed", usage: %{}}}
    end)
  end

  defp stub_extraction_llm do
    Mnemosyne.MockLLM
    |> stub(:chat, fn _messages, _opts ->
      {:ok, %LLM.Response{content: "0.8", model: "mock:test", usage: %{}}}
    end)

    Mnemosyne.MockLLM
    |> stub(:chat_structured, fn messages, _schema, _opts ->
      system_content =
        messages
        |> Enum.find(%{content: ""}, &(&1.role == :system))
        |> Map.get(:content)

      content =
        cond do
          system_content =~ "subgoal" ->
            %{"reasoning" => "analysis", "subgoal" => "test subgoal"}

          system_content =~ "factual knowledge" ->
            %{
              facts: [
                %{proposition: "fact one", concepts: ["c1", "c2"]},
                %{proposition: "fact two", concepts: ["c3"]}
              ]
            }

          system_content =~ "actionable instructions" ->
            %{
              instructions: [
                %{
                  intent: "goal",
                  condition: "always",
                  instruction: "thing",
                  expected_outcome: "result"
                }
              ]
            }

          system_content =~ "prescription quality" ->
            %{scores: [%{index: 0, return_score: 8}]}

          true ->
            %{}
        end

      {:ok, %LLM.Response{content: content, model: "mock:test", usage: %{}}}
    end)

    Mnemosyne.MockEmbedding
    |> stub(:embed, fn _text, _opts ->
      {:ok, %Embedding.Response{vectors: [@test_vector], model: "mock:embed", usage: %{}}}
    end)
    |> stub(:embed_batch, fn texts, _opts ->
      vectors = Enum.map(texts, fn _ -> @test_vector end)
      {:ok, %Embedding.Response{vectors: vectors, model: "mock:embed", usage: %{}}}
    end)
  end

  defp stub_retrieval_llm do
    Mnemosyne.MockLLM
    |> stub(:chat, fn messages, _opts ->
      system_content =
        messages
        |> Enum.find(%{content: ""}, &(&1.role == :system))
        |> Map.get(:content)

      content =
        cond do
          system_content =~ "classifying memory retrieval" -> "semantic"
          system_content =~ "planning memory retrieval" -> "BEAM VM"
          true -> "default"
        end

      {:ok, %LLM.Response{content: content, model: "mock:test", usage: %{}}}
    end)
  end

  defp stub_default_embedding do
    Mnemosyne.MockEmbedding
    |> stub(:embed, fn _text, _opts ->
      {:ok, %Embedding.Response{vectors: [@test_vector], model: "mock:embed", usage: %{}}}
    end)
    |> stub(:embed_batch, fn texts, _opts ->
      vectors = Enum.map(texts, fn _ -> @test_vector end)
      {:ok, %Embedding.Response{vectors: vectors, model: "mock:embed", usage: %{}}}
    end)
  end

  describe "Episode.append/4 telemetry" do
    test "emits start and stop events" do
      stub_append_cycle()
      attach_telemetry([:mnemosyne, :episode, :append, :start])
      attach_telemetry([:mnemosyne, :episode, :append, :stop])

      episode = Episode.new("Test goal")
      {:ok, _updated, _trace} = Episode.append(episode, "obs", "act", @default_opts)

      assert_received {:telemetry, [:mnemosyne, :episode, :append, :start], start_measurements,
                       %{episode_id: _}}

      assert is_integer(start_measurements.monotonic_time)

      assert_received {:telemetry, [:mnemosyne, :episode, :append, :stop], stop_measurements,
                       %{episode_id: _}}

      assert is_integer(stop_measurements.duration)
      assert is_integer(stop_measurements.step_count)
      assert is_boolean(stop_measurements.new_trajectory)
    end

    test "does not emit telemetry for closed episode" do
      attach_telemetry([:mnemosyne, :episode, :append, :start])

      episode = Episode.new("Test goal")
      {:ok, closed} = Episode.close(episode)

      {:error, %EpisodeError{reason: :episode_closed}} =
        Episode.append(closed, "obs", "act", @default_opts)

      refute_received {:telemetry, [:mnemosyne, :episode, :append, :start], _, _}
    end
  end

  describe "Structuring.extract/2 telemetry" do
    test "emits start and stop events" do
      stub_extraction_llm()
      attach_telemetry([:mnemosyne, :structuring, :extract, :start])
      attach_telemetry([:mnemosyne, :structuring, :extract, :stop])

      episode = Episode.new("Test goal")
      {:ok, episode, _trace} = Episode.append(episode, "obs", "act", @default_opts)
      {:ok, closed} = Episode.close(episode)

      stub_extraction_llm()
      {:ok, _cs} = Structuring.extract(closed, @default_opts)

      assert_received {:telemetry, [:mnemosyne, :structuring, :extract, :start], _,
                       %{episode_id: _}}

      assert_received {:telemetry, [:mnemosyne, :structuring, :extract, :stop], stop_measurements,
                       %{episode_id: _}}

      assert is_integer(stop_measurements.trajectory_count)
      assert is_integer(stop_measurements.nodes_created)
      assert is_integer(stop_measurements.links_created)
    end

    test "does not emit telemetry for unclosed episode" do
      attach_telemetry([:mnemosyne, :structuring, :extract, :start])

      episode = Episode.new("Test goal")

      {:error, %EpisodeError{reason: :episode_not_closed}} =
        Structuring.extract(episode, @default_opts)

      refute_received {:telemetry, [:mnemosyne, :structuring, :extract, :start], _, _}
    end
  end

  describe "Retrieval.retrieve/2 telemetry" do
    test "emits start and stop events" do
      stub_retrieval_llm()
      stub_default_embedding()
      attach_telemetry([:mnemosyne, :retrieval, :retrieve, :start])
      attach_telemetry([:mnemosyne, :retrieval, :retrieve, :stop])

      graph =
        Graph.put_node(Graph.new(), %Semantic{
          id: "sem_1",
          proposition: "Elixir runs on BEAM",
          confidence: 0.95,
          embedding: @test_vector
        })

      opts =
        @default_opts ++
          [
            backend:
              {Mnemosyne.GraphBackends.InMemory, %Mnemosyne.GraphBackends.InMemory{graph: graph}},
            value_function: %{
              module: ValueFunction.Default,
              params: %{
                semantic: %{
                  threshold: 0.0,
                  top_k: 20,
                  lambda: 0.01,
                  k: 5,
                  base_floor: 0.3,
                  beta: 1.0
                },
                tag: %{threshold: 0.0, top_k: 10, lambda: 0.01, k: 5, base_floor: 0.3, beta: 1.0}
              }
            }
          ]

      {:ok, _result, _trace} = Retrieval.retrieve("Tell me about Elixir", opts)

      assert_received {:telemetry, [:mnemosyne, :retrieval, :retrieve, :start], _, %{}}

      assert_received {:telemetry, [:mnemosyne, :retrieval, :retrieve, :stop], stop_measurements,
                       %{}}

      assert is_integer(stop_measurements.candidates_found)
    end
  end

  describe "Reasoning.reason/2 telemetry" do
    test "emits start and stop events" do
      Mnemosyne.MockLLM
      |> stub(:chat_structured, fn _messages, _schema, _opts ->
        {:ok,
         %LLM.Response{
           content: %{reasoning: "analysis", information: "Summary text."},
           model: "mock:test",
           usage: %{}
         }}
      end)

      attach_telemetry([:mnemosyne, :reasoning, :reason, :start])
      attach_telemetry([:mnemosyne, :reasoning, :reason, :stop])

      result = %Retrieval.Result{
        mode: :semantic,
        tags: ["test"],
        candidates: %{
          semantic: [
            TaggedCandidate.from_hop_0(
              %Semantic{id: "sem_1", proposition: "fact", confidence: 0.9},
              0.85
            )
          ]
        }
      }

      {:ok, _memory} = Reasoning.reason(result, llm: Mnemosyne.MockLLM, query: "test query")

      assert_received {:telemetry, [:mnemosyne, :reasoning, :reason, :start], _, %{}}

      assert_received {:telemetry, [:mnemosyne, :reasoning, :reason, :stop], stop_measurements,
                       %{}}

      assert is_list(stop_measurements.candidate_types)
      assert :semantic in stop_measurements.candidate_types
    end

    test "empty candidates still emit telemetry" do
      attach_telemetry([:mnemosyne, :reasoning, :reason, :start])
      attach_telemetry([:mnemosyne, :reasoning, :reason, :stop])

      result = %Retrieval.Result{mode: :mixed, tags: [], candidates: %{}}

      {:ok, _memory} = Reasoning.reason(result, llm: Mnemosyne.MockLLM, query: "test")

      assert_received {:telemetry, [:mnemosyne, :reasoning, :reason, :start], _, _}
      assert_received {:telemetry, [:mnemosyne, :reasoning, :reason, :stop], stop_measurements, _}
      assert stop_measurements.candidate_types == []
    end
  end
end
