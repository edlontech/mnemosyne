defmodule Mnemosyne.ModelCostIngestionTelemetryTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.LLM
  alias Mnemosyne.Trajectory

  setup :set_mimic_global

  setup do
    test_pid = self()
    handler_id = "ingestion-model-cost-#{System.unique_integer([:positive])}"

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

  test "attributes sequential and parallel ingestion model costs to the repository" do
    stub_model_calls()

    supervisor = :"model_cost_ingestion_#{System.unique_integer([:positive])}"
    repo_id = "cost-repo-#{System.unique_integer([:positive])}"
    source_id = "cost-source"
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

    trajectory = %Trajectory{
      source_id: source_id,
      goal: "Diagnose timeouts",
      steps: [%{observation: "Timeout", action: "Inspect logs"}],
      metadata: %{}
    }

    assert {:ok, _receipt} = Mnemosyne.ingest(repo_id, trajectory, supervisor: supervisor)

    events = collect_model_calls(12)

    assert Enum.frequencies_by(events, fn {_measurements, metadata} ->
             {metadata.kind, metadata.callback, metadata.step}
           end) == %{
             {:llm, :chat, :get_state} => 1,
             {:llm, :chat_structured, :get_subgoal} => 1,
             {:embedding, :embed, :get_subgoal} => 1,
             {:llm, :chat, :get_reward} => 1,
             {:llm, :chat_structured, :get_semantic} => 1,
             {:embedding, :embed_batch, :get_semantic} => 2,
             {:llm, :chat_structured, :get_procedural} => 1,
             {:embedding, :embed_batch, :get_procedural} => 2,
             {:llm, :chat_structured, :get_return} => 1,
             {:embedding, :embed_batch, :episodic_embedding} => 1
           }

    assert Enum.all?(events, fn {measurements, metadata} ->
             measurements.input_tokens == 7 and
               measurements.output_tokens == 3 and
               measurements.total_cost == 0.25 and
               metadata.repo_id == repo_id and
               metadata.labels == labels and
               metadata.operation == :ingest and
               metadata.source_id == source_id and
               metadata.currency == "USD" and
               metadata.status == :ok
           end)
  end

  defp config do
    {:ok, config} =
      Zoi.parse(Config.t(), %{
        llm: %{model: "test-model", opts: %{}},
        embedding: %{model: "test-embed", opts: %{}}
      })

    config
  end

  defp stub_model_calls do
    usage = %{input_tokens: 7, output_tokens: 3, total_cost: 0.25, currency: "USD"}

    stub(Mnemosyne.MockLLM, :chat, fn messages, _opts ->
      content =
        if system_content(messages) =~ "evaluating agent performance",
          do: "0.8",
          else: "Derived state"

      {:ok, %LLM.Response{content: content, model: "test-model", usage: usage}}
    end)

    stub(Mnemosyne.MockLLM, :chat_structured, fn messages, _schema, _opts ->
      prompt = system_content(messages)

      content =
        cond do
          prompt =~ "infer the subgoal" ->
            %{reasoning: "analysis", subgoal: "Inspect timeout evidence"}

          prompt =~ "factual knowledge" ->
            %{facts: [%{proposition: "The service timed out", concepts: ["timeouts"]}]}

          prompt =~ "actionable instructions" ->
            %{
              instructions: [
                %{
                  intent: "Diagnose a timeout",
                  condition: "A timeout occurs",
                  instruction: "Inspect logs",
                  expected_outcome: "The cause is identified"
                }
              ]
            }

          prompt =~ "prescription quality" ->
            %{scores: [%{index: 0, return_score: 8}]}
        end

      {:ok, %LLM.Response{content: content, model: "test-model", usage: usage}}
    end)

    stub(Mnemosyne.MockEmbedding, :embed, fn _text, _opts ->
      {:ok, %Embedding.Response{vectors: [[0.1, 0.2]], model: "test-embed", usage: usage}}
    end)

    stub(Mnemosyne.MockEmbedding, :embed_batch, fn texts, _opts ->
      vectors = Enum.map(texts, fn _ -> [0.1, 0.2] end)
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
  end
end
