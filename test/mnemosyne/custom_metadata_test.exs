defmodule Mnemosyne.CustomMetadataTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.Errors.Invalid.IngestionError
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.GraphBackends.Persistence.DETS
  alias Mnemosyne.LLM
  alias Mnemosyne.MockEmbedding
  alias Mnemosyne.MockLLM
  alias Mnemosyne.NodeMetadata
  alias Mnemosyne.Pipeline.Ingestion
  alias Mnemosyne.Trajectory

  setup :set_mimic_from_context

  test "caller metadata defaults to an empty map and survives usage updates" do
    custom = %{"ticket" => "PROJ-42", "details" => %{labels: ["important"]}}
    assert NodeMetadata.new().custom == %{}

    metadata =
      NodeMetadata.new(custom: custom)
      |> NodeMetadata.record_access()
      |> NodeMetadata.update_reward(0.9)

    assert metadata.custom == custom
    assert metadata.access_count == 1
    assert metadata.reward_count == 1
  end

  test "ingestion copies caller metadata to every extracted node without sending it to adapters" do
    stub_extraction()
    custom = %{"ticket" => "caller-only-marker", "details" => %{labels: ["important"]}}

    for metadata <- [%{}, custom] do
      trajectory = %Trajectory{
        source_id: "task-42",
        goal: "Diagnose timeouts",
        steps: [%{observation: "Request timed out", action: "Inspect logs"}],
        metadata: metadata
      }

      assert {:ok, changeset} =
               Ingestion.run(trajectory, llm: MockLLM, embedding: MockEmbedding)

      assert Enum.sort(Enum.map(changeset.additions, &Node.node_type/1)) ==
               [:episodic, :intent, :procedural, :semantic, :source, :subgoal, :tag]

      for node <- changeset.additions do
        assert changeset.metadata[node.id].custom == metadata
      end
    end
  end

  @tag :tmp_dir
  test "caller metadata is readable through the public API after ingestion and reopen", %{
    tmp_dir: tmp_dir
  } do
    stub_extraction()
    supervisor = Module.concat(__MODULE__, "Sup#{System.unique_integer([:positive])}")

    {:ok, config} =
      Zoi.parse(Config.t(), %{
        llm: %{model: "mock:test", opts: %{}},
        embedding: %{model: "mock:embed", opts: %{}}
      })

    start_supervised!(
      {Mnemosyne.Supervisor,
       name: supervisor, config: config, llm: MockLLM, embedding: MockEmbedding}
    )

    opts = [supervisor: supervisor]
    backend = {InMemory, persistence: {DETS, path: Path.join(tmp_dir, "custom.dets")}}
    open_opts = Keyword.put(opts, :backend, backend)
    {:ok, pid} = Mnemosyne.open_repo("custom", open_opts)
    allow(MockLLM, self(), pid)
    allow(MockEmbedding, self(), pid)

    trajectory = %Trajectory{
      source_id: "task-42",
      goal: "Diagnose timeouts",
      steps: [%{observation: "Request timed out", action: "Inspect logs"}],
      metadata: %{"ticket" => "caller-only-marker", "nested" => [1, %{important: true}]}
    }

    assert {:ok, receipt} = Mnemosyne.ingest("custom", trajectory, opts)
    assert {:ok, metadata} = Mnemosyne.get_metadata("custom", receipt.node_ids, opts)
    assert map_size(metadata) == 7
    assert Enum.all?(metadata, fn {_id, meta} -> meta.custom == trajectory.metadata end)
    assert {:ok, ^receipt} = Mnemosyne.ingest("custom", trajectory, opts)

    assert {:error, %IngestionError{reason: :source_conflict}} =
             Mnemosyne.ingest("custom", %{trajectory | metadata: %{changed: true}}, opts)

    assert :ok = Mnemosyne.close_repo("custom", opts)
    assert {:ok, _pid} = Mnemosyne.open_repo("custom", open_opts)
    assert {:ok, ^metadata} = Mnemosyne.get_metadata("custom", receipt.node_ids, opts)
    assert :ok = Mnemosyne.close_repo("custom", opts)
  end

  test "custom metadata does not change default candidate filtering or scores" do
    node = %Semantic{
      id: "fact",
      proposition: "Requests time out",
      confidence: 0.9,
      embedding: [1.0, 0.0]
    }

    metadata = NodeMetadata.new(access_count: 5)
    {:ok, backend} = InMemory.init([])
    {:ok, backend} = InMemory.apply_changeset(Changeset.add_node(Changeset.new(), node), backend)
    {:ok, baseline} = InMemory.update_metadata(%{node.id => metadata}, backend)

    {:ok, custom} =
      InMemory.update_metadata(
        %{node.id => %{metadata | custom: %{score: 0, audience: :hidden, ignored: ["anything"]}}},
        backend
      )

    vf = %{
      module: Mnemosyne.ValueFunction.Default,
      params: %{semantic: %{lambda: 0.0, threshold: 0.4}}
    }

    assert {:ok, expected, _} =
             InMemory.find_candidates([:semantic], [1.0, 0.0], [], vf, [], baseline)

    assert [{^node, 0.5}] =
             Enum.map(expected, fn {candidate, score} ->
               {%{candidate | created_at: nil}, score}
             end)

    assert {:ok, ^expected, _} =
             InMemory.find_candidates([:semantic], [1.0, 0.0], [], vf, [], custom)
  end

  @tag :tmp_dir
  test "legacy persisted metadata without custom loads with an empty map", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "legacy.dets")
    legacy = NodeMetadata.new(access_count: 7) |> Map.delete(:custom)
    {:ok, persistence} = DETS.init(path: path)
    assert :ok = DETS.save_metadata(%{"old-node" => legacy}, persistence)
    assert :ok = :dets.close(persistence.ref)

    assert {:ok, backend} = InMemory.init(persistence: {DETS, path: path})
    {DETS, reopened} = backend.persistence
    on_exit(fn -> :dets.close(reopened.ref) end)
    assert {:ok, metadata, _} = InMemory.get_metadata(["old-node"], backend)
    assert metadata["old-node"].custom == %{}
    assert metadata["old-node"].access_count == 7
  end

  defp stub_extraction do
    stub(MockLLM, :chat, fn messages, opts ->
      refute inspect({messages, opts}) =~ "caller-only-marker"
      content = system_content(messages)
      response = if content =~ "evaluating agent performance", do: "0.9", else: "derived state"
      {:ok, %LLM.Response{content: response, model: "mock:test", usage: %{}}}
    end)

    stub(MockLLM, :chat_structured, fn messages, _schema, opts ->
      refute inspect({messages, opts}) =~ "caller-only-marker"
      content = system_content(messages)

      response =
        cond do
          content =~ "infer the subgoal" ->
            %{reasoning: "analysis", subgoal: "Diagnose timeouts"}

          content =~ "factual knowledge" ->
            %{
              facts: [
                %{
                  proposition: "Requests time out",
                  concepts: ["timeouts"],
                  confidence: 0.9,
                  source_steps: [1]
                }
              ]
            }

          content =~ "actionable instructions" ->
            %{
              instructions: [
                %{
                  intent: "Diagnose timeouts",
                  condition: "On timeout",
                  instruction: "Inspect logs",
                  expected_outcome: "Find cause"
                }
              ]
            }

          content =~ "prescription quality" ->
            %{scores: [%{index: 0, return_score: 9}]}

          true ->
            flunk("Unexpected structured call: #{content}")
        end

      {:ok, %LLM.Response{content: response, model: "mock:test", usage: %{}}}
    end)

    stub(MockEmbedding, :embed, fn text, opts ->
      refute inspect({text, opts}) =~ "caller-only-marker"
      {:ok, %Embedding.Response{vectors: [[1.0, 0.0]], model: "mock:embed", usage: %{}}}
    end)

    stub(MockEmbedding, :embed_batch, fn texts, opts ->
      refute inspect({texts, opts}) =~ "caller-only-marker"

      {:ok,
       %Embedding.Response{
         vectors: Enum.map(texts, fn _ -> [1.0, 0.0] end),
         model: "mock:embed",
         usage: %{}
       }}
    end)
  end

  defp system_content(messages) do
    messages |> Enum.find(&(&1.role == :system)) |> Map.fetch!(:content)
  end
end
