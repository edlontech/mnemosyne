defmodule Mnemosyne.RecallTelemetryTest do
  use ExUnit.Case, async: false
  use AssertEventually, timeout: 500, interval: 10
  use Mimic

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.Errors.Framework.NotFoundError
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.LLM

  setup :set_mimic_global

  setup do
    test_pid = self()
    handler_id = "recall-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:mnemosyne, :recall, :execute, :start],
        [:mnemosyne, :recall, :execute, :stop]
      ],
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    stub_model_calls()
    supervisor = :"recall_telemetry_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Mnemosyne.Supervisor,
       name: supervisor,
       config: config(),
       llm: Mnemosyne.MockLLM,
       embedding: Mnemosyne.MockEmbedding}
    )

    repo_id = "recall-telemetry-repo-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Mnemosyne.open_repo(repo_id, supervisor: supervisor, backend: {InMemory, []})

    %{supervisor: supervisor, repo_id: repo_id}
  end

  test "reports a matched recall with result count, hops and mode", %{
    supervisor: supervisor,
    repo_id: repo_id
  } do
    assert :ok = Mnemosyne.apply_changeset(repo_id, semantic_changeset(), supervisor: supervisor)

    assert_eventually(
      match?({:ok, %Semantic{}}, Mnemosyne.get_node(repo_id, "semantic", supervisor: supervisor))
    )

    assert {:ok, result} =
             Mnemosyne.recall(repo_id, "Why do timeouts happen?",
               supervisor: supervisor,
               source_id: "task-1",
               max_hops: 1
             )

    assert_received {:telemetry, [:mnemosyne, :recall, :execute, :start], _,
                     %{repo_id: ^repo_id, source_id: "task-1"}}

    assert_received {:telemetry, [:mnemosyne, :recall, :execute, :stop], measurements, metadata}

    assert is_integer(measurements.duration)
    assert measurements.result_count == length(result.touched_nodes)
    assert measurements.result_count > 0
    assert measurements.hops == result.trace.hops

    assert %{
             repo_id: ^repo_id,
             source_id: "task-1",
             status: :ok,
             matched: true,
             mode: :mixed
           } = metadata
  end

  test "reports an unmatched recall when no nodes are returned", %{
    supervisor: supervisor,
    repo_id: repo_id
  } do
    assert {:ok, result} =
             Mnemosyne.recall(repo_id, "Why do timeouts happen?", supervisor: supervisor)

    assert result.touched_nodes == []

    assert_received {:telemetry, [:mnemosyne, :recall, :execute, :stop], measurements,
                     %{repo_id: ^repo_id, status: :ok, matched: false}}

    assert measurements.result_count == 0
  end

  test "reports an error status without match data", %{supervisor: supervisor} do
    assert {:error, %NotFoundError{resource: :repo}} =
             Mnemosyne.recall("missing-repo", "anything", supervisor: supervisor)

    assert_received {:telemetry, [:mnemosyne, :recall, :execute, :stop], measurements, metadata}

    assert %{repo_id: "missing-repo", source_id: nil, status: :error} = metadata
    refute Map.has_key?(metadata, :matched)
    refute Map.has_key?(measurements, :result_count)
  end

  defp config do
    {:ok, config} =
      Zoi.parse(Config.t(), %{
        llm: %{model: "test-model", opts: %{}},
        embedding: %{model: "test-embed", opts: %{}}
      })

    config
  end

  defp semantic_changeset do
    Changeset.add_node(Changeset.new(), %Semantic{
      id: "semantic",
      proposition: "Connection exhaustion causes timeouts",
      confidence: 0.9,
      embedding: List.duplicate(0.1, 128)
    })
  end

  defp stub_model_calls do
    stub(Mnemosyne.MockLLM, :chat, fn messages, _opts ->
      content =
        if system_content(messages) =~ "classifying memory retrieval",
          do: "mixed",
          else: "timeout"

      {:ok, %LLM.Response{content: content, model: "test-model", usage: %{}}}
    end)

    stub(Mnemosyne.MockLLM, :chat_structured, fn _messages, _schema, _opts ->
      {:ok,
       %LLM.Response{
         content: %{
           enough: true,
           top_indices: [],
           tags: ["timeout"],
           reasoning: "r",
           information: "info"
         },
         model: "test-model",
         usage: %{}
       }}
    end)

    stub(Mnemosyne.MockEmbedding, :embed, fn _text, _opts ->
      {:ok, %Embedding.Response{vectors: [List.duplicate(0.1, 128)], model: "e", usage: %{}}}
    end)

    stub(Mnemosyne.MockEmbedding, :embed_batch, fn texts, _opts ->
      vectors = Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)
      {:ok, %Embedding.Response{vectors: vectors, model: "e", usage: %{}}}
    end)
  end

  defp system_content(messages) do
    messages
    |> Enum.find(%{content: ""}, &(&1.role == :system))
    |> Map.fetch!(:content)
  end
end
