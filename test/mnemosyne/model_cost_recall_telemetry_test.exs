defmodule Mnemosyne.ModelCostRecallTelemetryTest do
  use ExUnit.Case, async: false
  use AssertEventually, timeout: 500, interval: 10
  use Mimic

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Episodic
  alias Mnemosyne.Graph.Node.Procedural
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.LLM
  alias Mnemosyne.Pipeline.RecallResult

  setup :set_mimic_global

  setup do
    test_pid = self()
    handler_id = "recall-model-cost-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:mnemosyne, :model, :call, :stop],
      fn event, measurements, metadata, _ ->
        send(test_pid, {:model_call, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "attributes multi-hop and parallel reasoning model costs to the repository" do
    stub_model_calls()

    supervisor = :"model_cost_recall_#{System.unique_integer([:positive])}"
    repo_id = "cost-repo-#{System.unique_integer([:positive])}"
    source_id = "recall-source"
    labels = %{environment: :test, team: "memory"}

    start_supervised!(
      {Mnemosyne.Supervisor,
       name: supervisor,
       config: config(),
       llm: Mnemosyne.MockLLM,
       embedding: Mnemosyne.MockEmbedding}
    )

    assert {:ok, _pid} =
             Mnemosyne.open_repo(repo_id,
               supervisor: supervisor,
               backend: {InMemory, []},
               telemetry_labels: labels
             )

    assert :ok =
             Mnemosyne.apply_changeset(repo_id, recall_changeset(), supervisor: supervisor)

    assert_eventually(
      match?({:ok, %Semantic{}}, Mnemosyne.get_node(repo_id, "semantic", supervisor: supervisor))
    )

    assert {:ok, %RecallResult{} = result} =
             Mnemosyne.recall(repo_id, "How should I diagnose the timeout?",
               supervisor: supervisor,
               source_id: source_id,
               max_hops: 1
             )

    assert result.reasoned.episodic == "The timeout happened during the deploy."
    assert result.reasoned.semantic == "The timeout was caused by connection exhaustion."
    assert result.reasoned.procedural == "Inspect connection pool metrics."
    assert result.trace.refinements != []

    events = collect_model_calls(10)

    assert Enum.frequencies_by(events, fn {_measurements, metadata} ->
             {metadata.kind, metadata.callback, metadata.step}
           end) == %{
             {:llm, :chat, :get_mode} => 1,
             {:llm, :chat, :get_plan} => 1,
             {:embedding, :embed_batch, :retrieval} => 1,
             {:llm, :chat_structured, :multi_hop_control} => 1,
             {:embedding, :embed, :retrieval_focus} => 1,
             {:llm, :chat_structured, :get_refined_query} => 1,
             {:embedding, :embed_batch, :get_refined_query} => 1,
             {:llm, :chat_structured, :reason_episodic} => 1,
             {:llm, :chat_structured, :reason_semantic} => 1,
             {:llm, :chat_structured, :reason_procedural} => 1
           }

    assert Enum.all?(events, fn {measurements, metadata} ->
             measurements.input_tokens == 11 and
               measurements.output_tokens == 4 and
               measurements.total_cost == 0.4 and
               metadata.repo_id == repo_id and
               metadata.labels == labels and
               metadata.operation == :recall and
               metadata.source_id == source_id and
               metadata.currency == "USD" and
               metadata.status == :ok
           end)
  end

  defp config do
    {:ok, config} =
      Zoi.parse(Config.t(), %{
        llm: %{model: "test-model", opts: %{}},
        embedding: %{model: "test-embed", opts: %{}},
        refinement_budget: 1
      })

    config
  end

  defp recall_changeset do
    vector = List.duplicate(0.1, 128)

    Changeset.new()
    |> Changeset.add_node(%Episodic{
      id: "episodic",
      observation: "A deploy timed out",
      action: "Inspected logs",
      state: "Degraded",
      subgoal: "Diagnose timeout",
      reward: 0.8,
      trajectory_id: "trajectory",
      embedding: vector
    })
    |> Changeset.add_node(%Semantic{
      id: "semantic",
      proposition: "Connection exhaustion causes timeouts",
      confidence: 0.9,
      embedding: vector
    })
    |> Changeset.add_node(%Procedural{
      id: "procedural",
      instruction: "Inspect connection pool metrics",
      condition: "A request times out",
      expected_outcome: "The exhausted pool is identified",
      return_score: 0.9,
      embedding: vector
    })
  end

  defp stub_model_calls do
    usage = %{input_tokens: 11, output_tokens: 4, total_cost: 0.4, currency: "USD"}

    stub(Mnemosyne.MockLLM, :chat, fn messages, _opts ->
      content =
        if system_content(messages) =~ "classifying memory retrieval",
          do: "mixed",
          else: "timeout\nconnection pool"

      {:ok, %LLM.Response{content: content, model: "test-model", usage: usage}}
    end)

    stub(Mnemosyne.MockLLM, :chat_structured, fn messages, _schema, _opts ->
      content =
        case system_content(messages) do
          "You are a retrieval controller" <> _ ->
            %{enough: false, top_indices: [0]}

          "You are a search refinement expert" <> _ ->
            %{tags: ["connection exhaustion"]}

          "You are an expert at synthesizing episodic memories" <> _ ->
            %{reasoning: "analysis", information: "The timeout happened during the deploy."}

          "You are an expert at synthesizing factual knowledge" <> _ ->
            %{
              reasoning: "analysis",
              information: "The timeout was caused by connection exhaustion."
            }

          "You are an expert at synthesizing procedural knowledge" <> _ ->
            %{reasoning: "analysis", information: "Inspect connection pool metrics."}
        end

      {:ok, %LLM.Response{content: content, model: "test-model", usage: usage}}
    end)

    stub(Mnemosyne.MockEmbedding, :embed, fn _text, _opts ->
      {:ok,
       %Embedding.Response{
         vectors: [List.duplicate(0.1, 128)],
         model: "test-embed",
         usage: usage
       }}
    end)

    stub(Mnemosyne.MockEmbedding, :embed_batch, fn texts, _opts ->
      vectors = Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)
      {:ok, %Embedding.Response{vectors: vectors, model: "test-embed", usage: usage}}
    end)
  end

  defp collect_model_calls(count) do
    Enum.map(1..count, fn _ ->
      assert_receive {:model_call, [:mnemosyne, :model, :call, :stop], measurements, metadata},
                     1_000

      {measurements, metadata}
    end)
  end

  defp system_content(messages) do
    messages
    |> Enum.find(%{content: ""}, &(&1.role == :system))
    |> Map.fetch!(:content)
    |> String.trim_leading()
  end
end
