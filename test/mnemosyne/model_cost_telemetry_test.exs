defmodule Mnemosyne.ModelCostTelemetryTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Mnemosyne.Config
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.IngestionReceipt
  alias Mnemosyne.Trajectory

  setup :set_mimic_global

  setup do
    test_pid = self()
    handler_id = "model-cost-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:mnemosyne, :model, :call, :stop],
        [:mnemosyne, :llm, :chat, :stop],
        [:mnemosyne, :llm, :chat_structured, :stop],
        [:mnemosyne, :embedding, :embed, :stop],
        [:mnemosyne, :embedding, :embed_batch, :stop]
      ],
      fn event, measurements, metadata, _ ->
        kind = if event == [:mnemosyne, :model, :call, :stop], do: :canonical, else: :adapter
        send(test_pid, {:telemetry, kind, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "keeps concurrent repository cost records isolated from adapter telemetry" do
    barrier = :ets.new(:model_cost_barrier, [:set, :public])
    barrier_ref = make_ref()
    stub_model_calls(self(), barrier, barrier_ref)

    supervisor = :"model_cost_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Mnemosyne.Supervisor,
       name: supervisor,
       config: config(),
       llm: Mnemosyne.Adapters.SycophantLLM,
       embedding: Mnemosyne.Adapters.SycophantEmbedding}
    )

    repo_a = %{id: "repository-a", labels: %{environment: :test, team: "alpha"}, source_id: "a"}
    repo_b = %{id: "repository-b", labels: %{environment: :test, team: "beta"}, source_id: "b"}

    for repo <- [repo_a, repo_b] do
      assert {:ok, _pid} =
               Mnemosyne.open_repo(repo.id,
                 supervisor: supervisor,
                 backend: {InMemory, []},
                 telemetry_labels: repo.labels
               )
    end

    task_a =
      Task.async(fn ->
        Mnemosyne.ingest(repo_a.id, trajectory(repo_a), supervisor: supervisor)
      end)

    task_b =
      Task.async(fn ->
        Mnemosyne.ingest(repo_b.id, trajectory(repo_b), supervisor: supervisor)
      end)

    assert_receive {:provider_barrier, "repository-a", provider_a, ^barrier_ref}, 1_000
    assert_receive {:provider_barrier, "repository-b", provider_b, ^barrier_ref}, 1_000

    send(provider_a, {:release_provider, barrier_ref})
    send(provider_b, {:release_provider, barrier_ref})

    assert {:ok, %IngestionReceipt{source_id: "a"}} = Task.await(task_a, 5_000)
    assert {:ok, %IngestionReceipt{source_id: "b"}} = Task.await(task_b, 5_000)

    events = collect_telemetry(48)
    {canonical, adapter_events} = Enum.split_with(events, &(elem(&1, 0) == :canonical))

    assert length(canonical) == 24
    assert length(adapter_events) == 24
    refute_receive {:telemetry, _kind, _event, _measurements, _metadata}, 0

    assert Enum.all?(canonical, fn {:canonical, _event, measurements, metadata} ->
             expected = Enum.find([repo_a, repo_b], &(&1.id == metadata.repo_id))

             expected != nil and
               metadata.labels == expected.labels and
               metadata.source_id == expected.source_id and
               metadata.operation == :ingest and
               metadata.status == :ok and
               measurements.input_tokens == 7 and
               measurements.output_tokens == 3
           end)

    assert Enum.all?(adapter_events, fn {:adapter, _event, _measurements, metadata} ->
             not Map.has_key?(metadata, :repo_id)
           end)

    total_costs =
      Enum.reduce(canonical, %{}, fn {:canonical, _event, measurements, metadata}, costs ->
        case measurements do
          %{total_cost: cost} -> Map.update(costs, metadata.repo_id, cost, &(&1 + cost))
          _ -> costs
        end
      end)

    assert total_costs == %{repo_a.id => 3.0}

    assert Enum.all?(canonical, fn {:canonical, _event, measurements, metadata} ->
             metadata.repo_id != repo_b.id or not Map.has_key?(measurements, :total_cost)
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

  defp trajectory(repo) do
    %Trajectory{
      source_id: repo.source_id,
      goal: "Diagnose #{repo.id}",
      steps: [%{observation: "#{repo.id} timed out", action: "Inspect #{repo.id} logs"}],
      metadata: %{}
    }
  end

  defp stub_model_calls(test_pid, barrier, barrier_ref) do
    stub(Sycophant, :generate_text, fn _model, messages, _opts ->
      marker = marker(messages)
      await_concurrent_provider_call(marker, test_pid, barrier, barrier_ref)

      text =
        if system_content(messages) =~ "evaluating agent performance",
          do: "0.8",
          else: "Derived state for #{marker}"

      {:ok, %Sycophant.Response{text: text, model: "test-model", usage: usage(marker)}}
    end)

    stub(Sycophant, :generate_object, fn _model, messages, _schema, _opts ->
      marker = marker(messages)
      await_concurrent_provider_call(marker, test_pid, barrier, barrier_ref)

      object =
        cond do
          system_content(messages) =~ "infer the subgoal" ->
            %{reasoning: "analysis", subgoal: "Inspect #{marker}"}

          system_content(messages) =~ "factual knowledge" ->
            %{facts: [%{proposition: "#{marker} timed out", concepts: [marker]}]}

          system_content(messages) =~ "actionable instructions" ->
            %{
              instructions: [
                %{
                  intent: "Diagnose #{marker}",
                  condition: "#{marker} times out",
                  instruction: "Inspect #{marker} logs",
                  expected_outcome: "#{marker} cause is identified"
                }
              ]
            }

          system_content(messages) =~ "prescription quality" ->
            %{scores: [%{index: 0, return_score: 8}]}
        end

      {:ok, %Sycophant.Response{object: object, model: "test-model", usage: usage(marker)}}
    end)

    stub(Sycophant, :embed, fn request, _opts ->
      marker = marker(request.inputs)
      await_concurrent_provider_call(marker, test_pid, barrier, barrier_ref)
      vectors = Enum.map(request.inputs, fn _ -> [0.1, 0.2] end)

      {:ok,
       %Sycophant.EmbeddingResponse{
         embeddings: %{float: vectors},
         model: "test-embed",
         usage: usage(marker)
       }}
    end)
  end

  defp await_concurrent_provider_call(marker, test_pid, barrier, barrier_ref) do
    if :ets.insert_new(barrier, {marker}) do
      send(test_pid, {:provider_barrier, marker, self(), barrier_ref})

      receive do
        {:release_provider, ^barrier_ref} -> :ok
      end
    end
  end

  defp usage("repository-a") do
    %Sycophant.Usage{
      input_tokens: 7,
      output_tokens: 3,
      total_cost: 0.25,
      pricing: %Sycophant.Pricing{currency: "USD"}
    }
  end

  defp usage("repository-b"), do: %Sycophant.Usage{input_tokens: 7, output_tokens: 3}

  defp marker(items) do
    if Enum.any?(items, &(item_content(&1) =~ "repository-a")),
      do: "repository-a",
      else: "repository-b"
  end

  defp item_content(%{content: content}), do: content
  defp item_content(content) when is_binary(content), do: content

  defp system_content(messages) do
    messages
    |> Enum.find(%{content: ""}, &(&1.role == :system))
    |> Map.fetch!(:content)
  end

  defp collect_telemetry(count) do
    Enum.map(1..count, fn _ ->
      assert_receive {:telemetry, kind, event, measurements, metadata}, 1_000
      {kind, event, measurements, metadata}
    end)
  end
end
