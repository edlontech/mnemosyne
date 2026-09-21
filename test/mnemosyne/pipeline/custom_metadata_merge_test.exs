defmodule Mnemosyne.Pipeline.CustomMetadataMergeTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Intent
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Tag
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.LLM
  alias Mnemosyne.MockEmbedding
  alias Mnemosyne.MockLLM
  alias Mnemosyne.NodeMetadata
  alias Mnemosyne.Pipeline.IntentMerger
  alias Mnemosyne.Pipeline.SemanticConsolidator
  alias Mnemosyne.Pipeline.TagDeduplicator

  setup :set_mimic_from_context

  test "semantic consolidation transfers caller data with survivor keys winning" do
    survivor = %Semantic{
      id: "survivor",
      proposition: "Requests time out",
      confidence: 1.0,
      embedding: [1.0, 0.0]
    }

    removed = %{survivor | id: "removed", proposition: "Upstream requests time out"}
    tag = %Tag{id: "tag", label: "timeouts"}

    changeset =
      Changeset.new()
      |> Changeset.add_node(survivor)
      |> Changeset.add_node(removed)
      |> Changeset.add_node(tag)
      |> Changeset.add_link(survivor.id, tag.id, :membership)
      |> Changeset.add_link(removed.id, tag.id, :membership)

    {:ok, backend} = InMemory.init([])
    {:ok, backend} = InMemory.apply_changeset(changeset, backend)

    {:ok, backend} =
      InMemory.update_metadata(
        %{
          survivor.id =>
            NodeMetadata.new(
              custom: %{shared: "caller-only-marker", survivor: true},
              access_count: 100
            ),
          removed.id => NodeMetadata.new(custom: %{shared: "removed", removed: true})
        },
        backend
      )

    expect(MockLLM, :chat_structured, fn messages, _schema, _opts ->
      refute inspect(messages) =~ "caller-only-marker"

      {:ok,
       %LLM.Response{
         content: %{merged_statement: "Merged fact", relationship: "SAME_TOPIC_MERGE_WELL"},
         model: "mock:test",
         usage: %{}
       }}
    end)

    expect(MockEmbedding, :embed, fn "Merged fact", _opts ->
      {:ok, %Embedding.Response{vectors: [[1.0, 0.0]], model: "mock:embed", usage: %{}}}
    end)

    config = %Config{
      llm: %{model: "mock:test", opts: %{}},
      embedding: %{model: "mock:embed", opts: %{}},
      value_function: %{params: %{semantic: %{lambda: 0.0}}}
    }

    assert {:ok, %{merged: 1}, {InMemory, backend}} =
             SemanticConsolidator.consolidate(
               backend: {InMemory, backend},
               config: config,
               llm: MockLLM,
               embedding: MockEmbedding
             )

    assert {:ok, metadata, _} = InMemory.get_metadata([survivor.id, removed.id], backend)
    assert Map.keys(metadata) == ["survivor"]

    assert metadata["survivor"].custom == %{
             shared: "caller-only-marker",
             survivor: true,
             removed: true
           }
  end

  test "intent identity merges preserve stored and batch custom maps even without rewards" do
    existing = %Intent{id: "stored", description: "Diagnose timeouts", embedding: [1.0, 0.0]}
    first = %{existing | id: "new-1"}
    second = %{existing | id: "new-2"}
    survivor_meta = NodeMetadata.new(custom: %{shared: "survivor", stored: true}, access_count: 7)

    {:ok, backend} = InMemory.init([])

    {:ok, backend} =
      InMemory.apply_changeset(Changeset.add_node(Changeset.new(), existing), backend)

    {:ok, backend} = InMemory.update_metadata(%{existing.id => survivor_meta}, backend)

    changeset = %Changeset{
      additions: [first, second],
      metadata: %{
        first.id => NodeMetadata.new(custom: %{shared: "first", first: true}),
        second.id => NodeMetadata.new(custom: %{shared: "second", second: true})
      }
    }

    opts = [
      backend: {InMemory, backend},
      config: %Config{
        llm: %{model: "mock:test", opts: %{}},
        embedding: %{model: "mock:embed", opts: %{}},
        intent_merge_threshold: 0.8,
        intent_identity_threshold: 0.95
      },
      value_function: %{
        module: Mnemosyne.ValueFunction.Default,
        params: %{intent: %{lambda: 0.0, base_floor: 1.0}}
      }
    ]

    assert {:ok, merged} = IntentMerger.merge(changeset, opts)
    assert merged.additions == []
    assert Map.keys(merged.metadata) == ["stored"]

    assert merged.metadata["stored"].custom == %{
             shared: "survivor",
             stored: true,
             first: true,
             second: true
           }

    assert merged.metadata["stored"].access_count == 7
    assert merged.metadata["stored"].reward_count == 0

    assert {:ok, batch} =
             IntentMerger.merge(changeset, Keyword.put(opts, :backend, {InMemory, %InMemory{}}))

    assert [%Intent{id: "new-1"}] = batch.additions
    assert batch.metadata["new-1"].custom == %{shared: "first", first: true, second: true}
    refute Map.has_key?(batch.metadata, "new-2")
  end

  test "intent synthesis and its failure fallback preserve custom metadata" do
    existing = %Intent{id: "stored", description: "Diagnose timeouts", embedding: [1.0, 0.0]}
    incoming = %{existing | id: "incoming", description: "Investigate timeouts"}

    stored =
      NodeMetadata.new(
        custom: %{shared: "caller-only-marker", stored: true},
        cumulative_reward: 2.0,
        reward_count: 2
      )

    source =
      NodeMetadata.new(
        custom: %{shared: "incoming", incoming: true},
        cumulative_reward: 0.5,
        reward_count: 1
      )

    {:ok, backend} = InMemory.init([])
    {:ok, backend} = InMemory.update_metadata(%{existing.id => stored}, backend)

    stub(InMemory, :find_candidates, fn [:intent], _vector, [], _vf, [], state ->
      {:ok, [{existing, 0.9}], state}
    end)

    for outcome <- [:success, :failure] do
      expect(MockLLM, :chat_structured, fn messages, _schema, _opts ->
        refute inspect(messages) =~ "caller-only-marker"

        if outcome == :success do
          {:ok,
           %LLM.Response{
             content: %{merged_intent: "Merged intent"},
             model: "mock:test",
             usage: %{}
           }}
        else
          {:error, :unavailable}
        end
      end)

      if outcome == :success do
        expect(MockEmbedding, :embed_batch, fn ["Merged intent"], _opts ->
          {:ok, %Embedding.Response{vectors: [[1.0, 0.0]], model: "mock:embed", usage: %{}}}
        end)
      end

      changeset = %Changeset{additions: [incoming], metadata: %{incoming.id => source}}

      config = %Config{
        llm: %{model: "mock:test", opts: %{}},
        embedding: %{model: "mock:embed", opts: %{}},
        intent_merge_threshold: 0.8,
        intent_identity_threshold: 0.95
      }

      assert {:ok, merged} =
               IntentMerger.merge(changeset,
                 backend: {InMemory, backend},
                 config: config,
                 llm: MockLLM,
                 embedding: MockEmbedding
               )

      assert merged.metadata[existing.id].custom == %{
               shared: "caller-only-marker",
               stored: true,
               incoming: true
             }

      assert merged.metadata[existing.id].cumulative_reward == 2.5
      assert merged.metadata[existing.id].reward_count == 3
      refute Map.has_key?(merged.metadata, incoming.id)
    end
  end

  test "tag deduplication combines batch and stored custom maps with survivor keys winning" do
    existing = %Tag{id: "stored", label: "timeouts"}
    first = %Tag{id: "new-1", label: " Timeouts "}
    second = %Tag{id: "new-2", label: "TIMEOUTS"}
    survivor_meta = NodeMetadata.new(custom: %{shared: "survivor", stored: true}, access_count: 7)
    first_meta = NodeMetadata.new(custom: %{shared: "first", first: true})
    second_meta = NodeMetadata.new(custom: %{shared: "second", second: true})

    {:ok, backend} = InMemory.init([])

    {:ok, backend} =
      InMemory.apply_changeset(Changeset.add_node(Changeset.new(), existing), backend)

    {:ok, backend} = InMemory.update_metadata(%{existing.id => survivor_meta}, backend)

    changeset = %Changeset{
      additions: [first, second],
      metadata: %{first.id => first_meta, second.id => second_meta}
    }

    assert {:ok, merged} = TagDeduplicator.deduplicate(changeset, backend: {InMemory, backend})
    assert merged.additions == []
    assert Map.keys(merged.metadata) == ["stored"]

    assert merged.metadata["stored"].custom == %{
             shared: "survivor",
             stored: true,
             first: true,
             second: true
           }

    assert merged.metadata["stored"].access_count == 7

    assert {:ok, batch} = TagDeduplicator.deduplicate(changeset, backend: {InMemory, %InMemory{}})
    assert [%Tag{id: "new-1"}] = batch.additions
    assert batch.metadata["new-1"].custom == %{shared: "first", first: true, second: true}
    refute Map.has_key?(batch.metadata, "new-2")
  end
end
