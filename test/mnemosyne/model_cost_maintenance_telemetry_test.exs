defmodule Mnemosyne.ModelCostMaintenanceTelemetryTest do
  use ExUnit.Case, async: false
  use AssertEventually, timeout: 500, interval: 10
  use Mimic

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Intent
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Tag
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.LLM
  alias Mnemosyne.NodeMetadata

  setup :set_mimic_global

  setup do
    test_pid = self()
    model_handler_id = "maintenance-model-cost-#{System.unique_integer([:positive])}"
    maintenance_handler_id = "maintenance-complete-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      model_handler_id,
      [:mnemosyne, :model, :call, :stop],
      fn event, measurements, metadata, _ ->
        send(test_pid, {:model_call, event, measurements, metadata})
      end,
      nil
    )

    :telemetry.attach_many(
      maintenance_handler_id,
      [
        [:mnemosyne, :consolidator, :consolidate, :stop],
        [:mnemosyne, :decay, :prune, :stop],
        [:mnemosyne, :episodic_validation, :validate, :stop],
        [:mnemosyne, :graph_repair, :repair, :stop]
      ],
      fn event, measurements, metadata, _ ->
        send(test_pid, {:maintenance, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(model_handler_id)
      :telemetry.detach(maintenance_handler_id)
    end)

    :ok
  end

  test "attributes direct changeset intent merging to apply_changeset" do
    stub_successful_intent_merge()

    {supervisor, repo_id, labels} = start_repo()
    seed_existing_intent(supervisor, repo_id)

    assert :ok =
             Mnemosyne.apply_changeset(
               repo_id,
               intent_changeset("intent-new", "Handle request failures", merge_vector()),
               supervisor: supervisor
             )

    events = collect_model_calls(2)

    assert Enum.frequencies_by(events, fn {_measurements, metadata} ->
             {metadata.kind, metadata.callback, metadata.step}
           end) == %{
             {:llm, :chat_structured, :merge_intent} => 1,
             {:embedding, :embed_batch, :merge_intent} => 1
           }

    assert Enum.all?(events, fn {measurements, metadata} ->
             measurements.total_cost == 0.1 and
               metadata.repo_id == repo_id and
               metadata.labels == labels and
               metadata.operation == :apply_changeset and
               metadata.source_id == nil and
               metadata.status == :ok
           end)
  end

  test "preserves ingestion attribution through write-time intent merging" do
    stub_successful_intent_merge()

    {supervisor, repo_id, labels} = start_repo()
    seed_existing_intent(supervisor, repo_id)

    source_id = "trajectory-source"

    stub(Mnemosyne.Pipeline.Ingestion, :run, fn _trajectory, _opts ->
      {:ok,
       intent_changeset(
         "intent-ingested",
         "Handle request failures",
         merge_vector()
       )}
    end)

    trajectory = %Mnemosyne.Trajectory{
      source_id: source_id,
      goal: "Handle failures",
      steps: [%{observation: "A request failed", action: "Inspect the error"}],
      metadata: %{}
    }

    assert {:ok, receipt} = Mnemosyne.ingest(repo_id, trajectory, supervisor: supervisor)
    assert receipt.source_id == source_id

    events = collect_model_calls(2)

    assert Enum.all?(events, fn {_measurements, metadata} ->
             metadata.repo_id == repo_id and
               metadata.labels == labels and
               metadata.operation == :ingest and
               metadata.source_id == source_id and
               metadata.step == :merge_intent
           end)
  end

  test "attributes semantic consolidation model calls" do
    stub_successful_semantic_merge()

    {supervisor, repo_id, labels} = start_repo()
    seed_semantic_pair(supervisor, repo_id)

    assert :ok = Mnemosyne.consolidate_semantics(repo_id, supervisor: supervisor)

    events = collect_model_calls(2)

    assert Enum.frequencies_by(events, fn {_measurements, metadata} ->
             {metadata.kind, metadata.callback, metadata.step}
           end) == %{
             {:llm, :chat_structured, :merge_semantic} => 1,
             {:embedding, :embed, :merge_semantic} => 1
           }

    assert Enum.all?(events, fn {_measurements, metadata} ->
             metadata.repo_id == repo_id and
               metadata.labels == labels and
               metadata.operation == :consolidate_semantics and
               metadata.source_id == nil and
               metadata.status == :ok
           end)

    assert_eventually(
      match?(
        {:ok, [_semantic]},
        Mnemosyne.get_nodes_by_type(repo_id, [:semantic], supervisor: supervisor)
      )
    )
  end

  test "emits an error record and preserves intent fallback on adapter failure" do
    stub(Mnemosyne.MockLLM, :chat_structured, fn _messages, _schema, _opts ->
      {:error, :llm_unavailable}
    end)

    {supervisor, repo_id, labels} = start_repo()
    seed_existing_intent(supervisor, repo_id)

    assert :ok =
             Mnemosyne.apply_changeset(
               repo_id,
               intent_changeset("intent-new", "Handle request failures", merge_vector()),
               supervisor: supervisor
             )

    assert [{%{}, metadata}] = collect_model_calls(1)
    assert metadata.status == :error
    assert metadata.operation == :apply_changeset
    assert metadata.repo_id == repo_id
    assert metadata.labels == labels
    assert metadata.step == :merge_intent

    assert_eventually(
      match?(
        {:ok, [%Intent{id: "intent-existing"}]},
        Mnemosyne.get_nodes_by_type(repo_id, [:intent], supervisor: supervisor)
      )
    )
  end

  test "emits an error record and keeps semantic nodes when embedding fails" do
    stub_semantic_llm()

    stub(Mnemosyne.MockEmbedding, :embed, fn _statement, _opts ->
      {:error, :embedding_unavailable}
    end)

    {supervisor, repo_id, labels} = start_repo()
    seed_semantic_pair(supervisor, repo_id)

    assert :ok = Mnemosyne.consolidate_semantics(repo_id, supervisor: supervisor)

    events = collect_model_calls(2)
    assert {_measurements, error_metadata} = Enum.find(events, &(elem(&1, 1).status == :error))
    assert error_metadata.operation == :consolidate_semantics
    assert error_metadata.repo_id == repo_id
    assert error_metadata.labels == labels
    assert error_metadata.callback == :embed
    assert error_metadata.step == :merge_semantic

    assert_receive {:maintenance, [:mnemosyne, :consolidator, :consolidate, :stop], _, _},
                   1_000

    assert {:ok, semantic_nodes} =
             Mnemosyne.get_nodes_by_type(repo_id, [:semantic], supervisor: supervisor)

    assert length(semantic_nodes) == 2
  end

  test "model-free maintenance and deletion emit no model-call records" do
    {supervisor, repo_id, _labels} = start_repo()
    seed_semantic_pair(supervisor, repo_id)

    assert :ok = Mnemosyne.decay_nodes(repo_id, supervisor: supervisor, threshold: 0.0)
    assert_receive {:maintenance, [:mnemosyne, :decay, :prune, :stop], _, _}, 1_000

    assert :ok = Mnemosyne.validate_episodic(repo_id, supervisor: supervisor)

    assert_receive {:maintenance, [:mnemosyne, :episodic_validation, :validate, :stop], _, _},
                   1_000

    assert :ok = Mnemosyne.repair_graph(repo_id, supervisor: supervisor)
    assert_receive {:maintenance, [:mnemosyne, :graph_repair, :repair, :stop], _, _}, 1_000

    assert :ok = Mnemosyne.delete_nodes(repo_id, ["semantic-a"], supervisor: supervisor)

    assert_eventually(
      match?(
        {:ok, nil},
        Mnemosyne.get_node(repo_id, "semantic-a", supervisor: supervisor)
      )
    )

    refute_receive {:model_call, [:mnemosyne, :model, :call, :stop], _, _}, 100
  end

  defp start_repo do
    supervisor = :"model_cost_maintenance_#{System.unique_integer([:positive])}"
    repo_id = "maintenance-cost-repo-#{System.unique_integer([:positive])}"
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

    {supervisor, repo_id, labels}
  end

  defp config do
    {:ok, config} =
      Zoi.parse(Config.t(), %{
        llm: %{model: "test-model", opts: %{}},
        embedding: %{model: "test-embed", opts: %{}},
        value_function: %{
          module: Mnemosyne.ValueFunction.Default,
          params: %{
            intent: %{
              threshold: 0.0,
              top_k: 20,
              lambda: 0.0,
              k: 5,
              base_floor: 1.0,
              beta: 1.0
            }
          }
        }
      })

    config
  end

  defp seed_existing_intent(supervisor, repo_id) do
    assert :ok =
             Mnemosyne.apply_changeset(
               repo_id,
               intent_changeset("intent-existing", "Handle errors", [1.0, 0.0]),
               supervisor: supervisor
             )

    assert_eventually(
      match?(
        {:ok, %Intent{}},
        Mnemosyne.get_node(repo_id, "intent-existing", supervisor: supervisor)
      )
    )
  end

  defp intent_changeset(id, description, embedding) do
    Changeset.new()
    |> Changeset.add_node(%Intent{id: id, description: description, embedding: embedding})
    |> Changeset.put_metadata(id, NodeMetadata.new())
  end

  defp seed_semantic_pair(supervisor, repo_id) do
    changeset =
      Changeset.new()
      |> Changeset.add_node(%Semantic{
        id: "semantic-a",
        proposition: "Elixir is functional",
        confidence: 1.0,
        embedding: [1.0, 0.0]
      })
      |> Changeset.add_node(%Semantic{
        id: "semantic-b",
        proposition: "Elixir is a functional language",
        confidence: 1.0,
        embedding: merge_vector()
      })
      |> Changeset.add_node(%Tag{id: "tag-elixir", label: "elixir", embedding: [1.0, 0.0]})
      |> Changeset.add_link("semantic-a", "tag-elixir", :membership)
      |> Changeset.add_link("semantic-b", "tag-elixir", :membership)
      |> Changeset.put_metadata("semantic-a", NodeMetadata.new())
      |> Changeset.put_metadata("semantic-b", NodeMetadata.new())
      |> Changeset.put_metadata("tag-elixir", NodeMetadata.new())

    assert :ok = Mnemosyne.apply_changeset(repo_id, changeset, supervisor: supervisor)

    assert_eventually(
      match?(
        {:ok, [_, _]},
        Mnemosyne.get_nodes_by_type(repo_id, [:semantic], supervisor: supervisor)
      )
    )
  end

  defp merge_vector, do: [0.88, :math.sqrt(1.0 - 0.88 * 0.88)]

  defp stub_successful_intent_merge do
    usage = %{input_tokens: 3, output_tokens: 2, total_cost: 0.1, currency: "USD"}

    stub(Mnemosyne.MockLLM, :chat_structured, fn _messages, _schema, _opts ->
      {:ok,
       %LLM.Response{
         content: %{merged_intent: "Handle request errors"},
         model: "test-model",
         usage: usage
       }}
    end)

    stub(Mnemosyne.MockEmbedding, :embed_batch, fn ["Handle request errors"], _opts ->
      {:ok, %Embedding.Response{vectors: [[1.0, 0.0]], model: "test-embed", usage: usage}}
    end)
  end

  defp stub_successful_semantic_merge do
    usage = %{input_tokens: 5, output_tokens: 3, total_cost: 0.2, currency: "USD"}
    stub_semantic_llm(usage)

    stub(Mnemosyne.MockEmbedding, :embed, fn "Elixir is a functional language", _opts ->
      {:ok, %Embedding.Response{vectors: [[1.0, 0.0]], model: "test-embed", usage: usage}}
    end)
  end

  defp stub_semantic_llm(usage \\ %{}) do
    stub(Mnemosyne.MockLLM, :chat_structured, fn _messages, _schema, _opts ->
      {:ok,
       %LLM.Response{
         content: %{
           merged_statement: "Elixir is a functional language",
           relationship: "SAME_TOPIC_MERGE_WELL"
         },
         model: "test-model",
         usage: usage
       }}
    end)
  end

  defp collect_model_calls(count) do
    Enum.map(1..count, fn _ ->
      assert_receive {:model_call, [:mnemosyne, :model, :call, :stop], measurements, metadata},
                     1_000

      {measurements, metadata}
    end)
  end
end
