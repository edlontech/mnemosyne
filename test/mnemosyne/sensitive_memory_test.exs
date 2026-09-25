Mimic.copy(Mnemosyne.Pipeline.SemanticConsolidator)

defmodule Mnemosyne.SensitiveMemoryTest.Backend do
  @moduledoc false
  alias Mnemosyne.GraphBackends.InMemory

  def init(opts), do: {:ok, Keyword.fetch!(opts, :state)}
  defdelegate apply_changeset(changeset, state), to: InMemory
  defdelegate get_ingestion(source, state), to: InMemory
  defdelegate commit_ingestion(record, changeset, state), to: InMemory
  defdelegate delete_ingestion(source, state), to: InMemory
  defdelegate delete_nodes(ids, state), to: InMemory
  defdelegate find_candidates(types, query, tags, config, opts, state), to: InMemory
  defdelegate get_node(id, state), to: InMemory
  defdelegate get_linked_nodes(ids, type, state), to: InMemory
  defdelegate get_nodes_by_type(types, state), to: InMemory
  defdelegate get_metadata(ids, state), to: InMemory
  defdelegate update_metadata(metadata, state), to: InMemory
  defdelegate delete_metadata(ids, state), to: InMemory
end

defmodule Mnemosyne.SensitiveMemoryTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding.Response, as: EmbeddingResponse
  alias Mnemosyne.Errors.Invalid.AccessError
  alias Mnemosyne.Errors.Invalid.IngestionError
  alias Mnemosyne.Graph
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node
  alias Mnemosyne.Graph.Node.Intent
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Tag
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.GraphBackends.Persistence.DETS
  alias Mnemosyne.LLM.Response, as: LLMResponse
  alias Mnemosyne.MockEmbedding
  alias Mnemosyne.MockLLM
  alias Mnemosyne.NodeMetadata
  alias Mnemosyne.Pipeline.Ingestion
  alias Mnemosyne.Pipeline.SemanticConsolidator
  alias Mnemosyne.Supervisor, as: MneSupervisor
  alias Mnemosyne.Trajectory

  setup :set_mimic_from_context

  setup do
    {:ok, config} =
      Zoi.parse(Config.t(), %{
        llm: %{model: "test-model", opts: %{}},
        embedding: %{model: "test-embed", opts: %{}}
      })

    name = :"sensitive_sup_#{System.unique_integer([:positive])}"

    start_supervised!(
      {MneSupervisor, name: name, config: config, llm: MockLLM, embedding: MockEmbedding}
    )

    %{sup: name, repo: "shared-repo", config: config}
  end

  defp open(ctx, opts \\ []) do
    Mnemosyne.open_repo(
      ctx.repo,
      Keyword.merge(
        [
          supervisor: ctx.sup,
          backend: {__MODULE__.Backend, state: seeded_state()},
          access_control: [policy: :membership_and_audience]
        ],
        opts
      )
    )
  end

  defp seeded_state do
    nodes =
      for {id, fact} <- [
            {"shared", "Shared knowledge"},
            {"secret", "Security knowledge"},
            {"legacy", "Unclassified knowledge"}
          ] do
        %Semantic{id: id, proposition: fact, confidence: 0.9, embedding: [1.0, 0.0]}
      end

    graph =
      Enum.reduce(nodes, Graph.new(), &Graph.put_node(&2, &1))
      |> Graph.link("shared", "secret", :sibling)

    %InMemory{
      graph: graph,
      metadata: %{
        "shared" => NodeMetadata.new(audience: :repo),
        "secret" => NodeMetadata.new(audience: [{"org", "security"}], access_count: 100),
        "legacy" => NodeMetadata.new()
      }
    }
  end

  defp auth(groups \\ []) do
    %{principal: "alice", repos: ["shared-repo"], groups: groups}
  end

  test "public reads hide restricted and unclassified nodes and strip hidden link IDs", ctx do
    assert {:ok, _} = open(ctx)
    opts = [supervisor: ctx.sup, authorization: auth()]

    assert {:ok, nil} = Mnemosyne.get_node(ctx.repo, "secret", opts)
    assert {:ok, nil} = Mnemosyne.get_node(ctx.repo, "legacy", opts)

    assert {:ok, %Semantic{id: "shared", links: links}} =
             Mnemosyne.get_node(ctx.repo, "shared", opts)

    assert MapSet.size(links.sibling) == 0

    assert {:ok, [%Semantic{id: "shared"}]} =
             Mnemosyne.get_nodes_by_type(ctx.repo, [:semantic], opts)

    assert {:ok, [%Semantic{id: "shared"}]} =
             Mnemosyne.get_linked_nodes(ctx.repo, ["shared", "secret", "legacy"], opts)

    assert {:ok, metadata} =
             Mnemosyne.get_metadata(ctx.repo, ["shared", "secret", "legacy"], opts)

    assert Map.keys(metadata) == ["shared"]
    assert {:ok, [{%Semantic{id: "shared"}, _}]} = Mnemosyne.latest(ctx.repo, 10, opts)

    assert {:ok, %Semantic{id: "secret"}} =
             Mnemosyne.get_node(ctx.repo, "secret",
               supervisor: ctx.sup,
               authorization: auth([{"org", "security"}])
             )

    assert {:ok, nil} = Mnemosyne.get_node(ctx.repo, "secret", opts)
    assert {:error, _} = Mnemosyne.get_node(ctx.repo, "shared", supervisor: ctx.sup)
  end

  test "recall never sends hidden knowledge to models or returns it in traces", ctx do
    config = ctx.config
    config = put_in(config.value_function.params.semantic.top_k, 1)
    assert {:ok, store} = open(ctx, config: config)
    parent = self()

    stub(MockLLM, :chat, fn messages, _opts ->
      text = Enum.map_join(messages, "\n", & &1.content)
      send(parent, {:prompt, text})
      content = if text =~ "classifying memory retrieval", do: "semantic", else: "knowledge"
      {:ok, %LLMResponse{content: content, model: "test", usage: %{}}}
    end)

    stub(MockLLM, :chat_structured, fn messages, _schema, _opts ->
      text = Enum.map_join(messages, "\n", & &1.content)
      send(parent, {:prompt, text})

      {:ok,
       %LLMResponse{
         content: %{reasoning: "facts", information: "Shared knowledge"},
         model: "test",
         usage: %{}
       }}
    end)

    stub(MockEmbedding, :embed, fn text, _opts ->
      send(parent, {:embedding, text})
      {:ok, %EmbeddingResponse{vectors: [[1.0, 0.0]], model: "test", usage: %{}}}
    end)

    stub(MockEmbedding, :embed_batch, fn texts, _opts ->
      send(parent, {:embedding, Enum.join(texts, "\n")})

      {:ok,
       %EmbeddingResponse{
         vectors: Enum.map(texts, fn _ -> [1.0, 0.0] end),
         model: "test",
         usage: %{}
       }}
    end)

    allow(MockLLM, self(), store)
    allow(MockEmbedding, self(), store)

    assert {:ok, result} =
             Mnemosyne.recall(ctx.repo, "What do we know?",
               supervisor: ctx.sup,
               authorization: auth(),
               max_hops: 2
             )

    assert Enum.map(result.touched_nodes, & &1.id) == ["shared"]
    assert Map.keys(result.trace.scores) == ["shared"]

    for {_kind, text} <- drain_model_messages([]) do
      refute text =~ "Security knowledge"
      refute text =~ "Unclassified knowledge"
      refute text =~ "secret"
    end

    assert {:error, _} = Mnemosyne.recall(ctx.repo, "No identity", supervisor: ctx.sup)
    refute_received {:prompt, _}
    refute_received {:embedding, _}
  end

  defp drain_model_messages(messages) do
    receive do
      {kind, text} when kind in [:prompt, :embedding] ->
        drain_model_messages([{kind, text} | messages])
    after
      0 -> messages
    end
  end

  test "ingestion rejects missing audiences and unauthorized writers before extraction", ctx do
    assert {:ok, store} = open(ctx)
    parent = self()

    stub(Ingestion, :run, fn _trajectory, _opts ->
      send(parent, :extraction_started)
      {:ok, Changeset.new()}
    end)

    allow(Ingestion, self(), store)

    trajectory = %Trajectory{
      source_id: "new",
      goal: "Investigate",
      steps: [%{observation: "Issue", action: "Inspect"}]
    }

    opts = [supervisor: ctx.sup, authorization: auth()]
    assert {:error, _} = Mnemosyne.ingest(ctx.repo, trajectory, opts)

    assert {:error, _} =
             Mnemosyne.ingest(ctx.repo, %{trajectory | audience: [{"org", "security"}]}, opts)

    assert {:error, _} =
             Mnemosyne.ingest(
               ctx.repo,
               %{trajectory | audience: :repo},
               supervisor: ctx.sup
             )

    refute_received :extraction_started
  end

  test "stored nodes inherit the audience and retries cannot change it", ctx do
    assert {:ok, store} = open(ctx)

    stub(Ingestion, :run, fn _trajectory, _opts ->
      cs =
        Changeset.new()
        |> Changeset.add_node(%Semantic{
          id: "ingested",
          proposition: "Restricted result",
          confidence: 0.9
        })
        |> Changeset.add_node(%Tag{
          id: "new-tag",
          label: "new concept"
        })
        |> Changeset.add_link("ingested", "new-tag", :membership)

      {:ok, cs}
    end)

    allow(Ingestion, self(), store)

    trajectory = %Trajectory{
      source_id: "new",
      goal: "Investigate",
      audience: [{"org", "security"}],
      steps: [%{observation: "Issue", action: "Inspect"}]
    }

    opts = [supervisor: ctx.sup, authorization: auth([{"org", "security"}])]
    assert {:ok, receipt} = Mnemosyne.ingest(ctx.repo, trajectory, opts)
    assert {:ok, ^receipt} = Mnemosyne.ingest(ctx.repo, trajectory, opts)

    assert {:error, %IngestionError{reason: :source_conflict}} =
             Mnemosyne.ingest(ctx.repo, %{trajectory | audience: :repo}, opts)

    assert {:ok, metadata} = Mnemosyne.get_metadata(ctx.repo, receipt.node_ids, opts)
    assert map_size(metadata) == 2
    assert Enum.all?(metadata, fn {_id, meta} -> meta.audience == [{"org", "security"}] end)
    assert {:ok, %Semantic{id: "ingested"}} = Mnemosyne.get_node(ctx.repo, "ingested", opts)

    assert {:ok, nil} =
             Mnemosyne.get_node(ctx.repo, "ingested", supervisor: ctx.sup, authorization: auth())
  end

  test "forget requires ingest rights for the recorded audience", ctx do
    assert {:ok, store} = open(ctx)

    stub(Ingestion, :run, fn _trajectory, _opts ->
      cs =
        Changeset.add_node(Changeset.new(), %Semantic{
          id: "ingested",
          proposition: "Restricted result",
          confidence: 0.9
        })

      {:ok, cs}
    end)

    allow(Ingestion, self(), store)

    trajectory = %Trajectory{
      source_id: "new",
      goal: "Investigate",
      audience: [{"org", "security"}],
      steps: [%{observation: "Issue", action: "Inspect"}]
    }

    writer = [supervisor: ctx.sup, authorization: auth([{"org", "security"}])]
    assert {:ok, _receipt} = Mnemosyne.ingest(ctx.repo, trajectory, writer)

    assert {:error, %AccessError{}} = Mnemosyne.forget(ctx.repo, "new", supervisor: ctx.sup)
    assert {:error, %AccessError{}} = Mnemosyne.forget(ctx.repo, "nope", supervisor: ctx.sup)

    assert {:error, %AccessError{}} =
             Mnemosyne.forget(ctx.repo, "new", supervisor: ctx.sup, authorization: auth())

    assert {:ok, %Semantic{id: "ingested"}} = Mnemosyne.get_node(ctx.repo, "ingested", writer)

    assert {:ok, %{deleted_ids: ["ingested"]}} = Mnemosyne.forget(ctx.repo, "new", writer)
    assert {:ok, nil} = Mnemosyne.get_node(ctx.repo, "ingested", writer)
  end

  test "tag and intent deduplication never crosses audiences", ctx do
    assert {:ok, store} = open(ctx)

    stub(Ingestion, :run, fn trajectory, _opts ->
      tag = %Tag{id: trajectory.source_id <> "-tag", label: "same label"}

      intent = %Intent{
        id: trajectory.source_id <> "-intent",
        description: "same intent",
        embedding: [1.0, 0.0]
      }

      {:ok,
       Changeset.new()
       |> Changeset.add_node(tag)
       |> Changeset.add_node(intent)}
    end)

    allow(Ingestion, self(), store)

    trajectory = %Trajectory{
      source_id: "public",
      goal: "Investigate",
      audience: :repo,
      steps: [%{observation: "Issue", action: "Inspect"}]
    }

    opts = [supervisor: ctx.sup, authorization: auth([{"org", "security"}])]

    assert {:ok, _} = Mnemosyne.ingest(ctx.repo, trajectory, opts)

    assert {:ok, _} =
             Mnemosyne.ingest(
               ctx.repo,
               %{trajectory | source_id: "private", audience: [{"org", "security"}]},
               opts
             )

    assert {:ok, tags} = Mnemosyne.get_nodes_by_type(ctx.repo, [:tag], opts)
    assert Enum.sort(Enum.map(tags, & &1.id)) == ["private-tag", "public-tag"]
    assert {:ok, intents} = Mnemosyne.get_nodes_by_type(ctx.repo, [:intent], opts)
    assert Enum.sort(Enum.map(intents, & &1.id)) == ["private-intent", "public-intent"]

    assert {:ok, %Tag{id: "public-tag"}} =
             Mnemosyne.get_node(
               ctx.repo,
               "public-tag",
               supervisor: ctx.sup,
               authorization: auth()
             )
  end

  test "raw changesets cannot bypass immutable audiences", ctx do
    assert {:ok, store} = open(ctx)

    cs =
      Changeset.put_metadata(
        Changeset.new(),
        "secret",
        NodeMetadata.new(audience: :repo)
      )

    assert {:error, _} =
             Mnemosyne.apply_changeset(ctx.repo, cs,
               supervisor: ctx.sup,
               authorization: auth([{"org", "security"}])
             )

    GenServer.cast(store, {:apply_changeset, cs})

    assert {:ok, nil} =
             Mnemosyne.get_node(ctx.repo, "secret", supervisor: ctx.sup, authorization: auth())
  end

  test "explicit startup classification assigns only previously unlabeled memories", ctx do
    assert {:ok, _} = open(ctx, legacy_audience: [{"org", "security"}])
    restricted = [supervisor: ctx.sup, authorization: auth([{"org", "security"}])]
    assert {:ok, %Semantic{id: "legacy"}} = Mnemosyne.get_node(ctx.repo, "legacy", restricted)

    assert {:ok, nil} =
             Mnemosyne.get_node(ctx.repo, "legacy", supervisor: ctx.sup, authorization: auth())

    assert {:ok, %Semantic{id: "shared"}} =
             Mnemosyne.get_node(ctx.repo, "shared", supervisor: ctx.sup, authorization: auth())

    assert {:ok, metadata} = Mnemosyne.get_metadata(ctx.repo, ["legacy", "shared"], restricted)
    assert metadata["legacy"].audience == [{"org", "security"}]
    assert metadata["shared"].audience == :repo
  end

  test "deletion and maintenance require trusted repository membership", ctx do
    assert {:ok, _} = open(ctx)
    opts = [supervisor: ctx.sup]
    assert {:error, _} = Mnemosyne.delete_nodes(ctx.repo, ["secret"], opts)
    assert {:error, _} = Mnemosyne.consolidate_semantics(ctx.repo, opts)
    assert {:error, _} = Mnemosyne.decay_nodes(ctx.repo, opts)
    assert {:error, _} = Mnemosyne.validate_episodic(ctx.repo, opts)
    assert {:error, _} = Mnemosyne.repair_graph(ctx.repo, opts)
  end

  test "ingestion waits for protected maintenance instead of being overwritten by its snapshot",
       ctx do
    assert {:ok, store} = open(ctx)
    parent = self()

    stub(SemanticConsolidator, :consolidate, fn opts ->
      send(parent, {:maintenance_started, self()})

      receive do
        :finish -> {:ok, %{checked: 0, deleted: 0, merged: 0, deleted_ids: []}, opts[:backend]}
      end
    end)

    stub(Ingestion, :run, fn _trajectory, _opts ->
      send(parent, :extracted)

      {:ok,
       Changeset.add_node(Changeset.new(), %Semantic{
         id: "after-maintenance",
         proposition: "New fact",
         confidence: 0.9
       })}
    end)

    allow(SemanticConsolidator, self(), store)
    allow(Ingestion, self(), store)
    opts = [supervisor: ctx.sup, authorization: auth()]
    assert :ok = Mnemosyne.consolidate_semantics(ctx.repo, opts)
    assert_receive {:maintenance_started, worker}

    trajectory = %Trajectory{
      source_id: "during-maintenance",
      goal: "Investigate",
      audience: :repo,
      steps: [%{observation: "Issue", action: "Inspect"}]
    }

    task = Task.async(fn -> Mnemosyne.ingest(ctx.repo, trajectory, opts) end)
    assert_receive :extracted
    ref = task.ref
    refute_receive {^ref, _}, 50
    send(worker, :finish)
    assert {:ok, _receipt} = Task.await(task)

    assert {:ok, %Semantic{id: "after-maintenance"}} =
             Mnemosyne.get_node(ctx.repo, "after-maintenance", opts)
  end

  @tag :tmp_dir
  test "audiences and source receipts survive a DETS restart without reclassification", ctx do
    backend =
      {InMemory, persistence: {DETS, path: Path.join(ctx.tmp_dir, "protected.dets")}}

    assert {:ok, store} = open(ctx, backend: backend)

    stub(Ingestion, :run, fn _trajectory, _opts ->
      {:ok,
       Changeset.add_node(Changeset.new(), %Semantic{
         id: "durable",
         proposition: "Durable restricted fact",
         confidence: 0.9
       })}
    end)

    allow(Ingestion, self(), store)

    trajectory = %Trajectory{
      source_id: "durable-source",
      goal: "Investigate",
      audience: [{"org", "security"}],
      steps: [%{observation: "Issue", action: "Inspect"}]
    }

    opts = [supervisor: ctx.sup, authorization: auth([{"org", "security"}])]
    assert {:ok, receipt} = Mnemosyne.ingest(ctx.repo, trajectory, opts)
    assert :ok = Mnemosyne.close_repo(ctx.repo, supervisor: ctx.sup)
    assert {:ok, _} = open(ctx, backend: backend, legacy_audience: :repo)
    assert {:ok, ^receipt} = Mnemosyne.ingest(ctx.repo, trajectory, opts)
    assert {:ok, %Semantic{id: "durable"}} = Mnemosyne.get_node(ctx.repo, "durable", opts)

    assert {:ok, nil} =
             Mnemosyne.get_node(ctx.repo, "durable", supervisor: ctx.sup, authorization: auth())

    assert {:ok, %{"durable" => %{audience: [{"org", "security"}]}}} =
             Mnemosyne.get_metadata(ctx.repo, ["durable"], opts)
  end

  test "real extraction labels every derived node type", ctx do
    assert {:ok, store} = open(ctx, backend: {InMemory, []})

    stub(MockLLM, :chat, fn messages, _opts ->
      system = hd(messages).content
      content = if system =~ "evaluating agent performance", do: "0.9", else: "Derived state"
      {:ok, %LLMResponse{content: content, model: "test", usage: %{}}}
    end)

    stub(MockLLM, :chat_structured, fn messages, _schema, _opts ->
      system = hd(messages).content

      content =
        cond do
          system =~ "infer the subgoal" ->
            %{reasoning: "analysis", subgoal: "Investigate"}

          system =~ "factual knowledge" ->
            %{
              facts: [
                %{
                  proposition: "Inspect logs to find failures",
                  concepts: ["logs"],
                  confidence: 0.9,
                  source_steps: [1]
                }
              ]
            }

          system =~ "actionable instructions" ->
            %{
              instructions: [
                %{
                  intent: "Investigate failures",
                  condition: "When a failure occurs",
                  instruction: "Inspect logs",
                  expected_outcome: "Identify the cause",
                  source_steps: [1]
                }
              ]
            }

          system =~ "prescription quality" ->
            %{scores: [%{index: 0, return_score: 9}]}
        end

      {:ok, %LLMResponse{content: content, model: "test", usage: %{}}}
    end)

    stub(MockEmbedding, :embed, fn _text, _opts ->
      {:ok, %EmbeddingResponse{vectors: [[1.0, 0.0]], model: "test", usage: %{}}}
    end)

    stub(MockEmbedding, :embed_batch, fn texts, _opts ->
      {:ok,
       %EmbeddingResponse{
         vectors: Enum.map(texts, fn _ -> [1.0, 0.0] end),
         model: "test",
         usage: %{}
       }}
    end)

    allow(MockLLM, self(), store)
    allow(MockEmbedding, self(), store)

    trajectory = %Trajectory{
      source_id: "real-extraction",
      goal: "Investigate",
      audience: [{"org", "security"}],
      steps: [%{observation: "Issue", action: "Inspect"}]
    }

    opts = [supervisor: ctx.sup, authorization: auth([{"org", "security"}])]
    assert {:ok, receipt} = Mnemosyne.ingest(ctx.repo, trajectory, opts)
    assert {:ok, nodes} = Mnemosyne.get_linked_nodes(ctx.repo, receipt.node_ids, opts)

    assert nodes |> Enum.map(&Node.node_type/1) |> Enum.uniq() |> Enum.sort() ==
             [:episodic, :intent, :procedural, :semantic, :source, :subgoal, :tag]

    assert {:ok, metadata} = Mnemosyne.get_metadata(ctx.repo, receipt.node_ids, opts)
    assert map_size(metadata) == length(nodes)
    assert Enum.all?(metadata, fn {_id, meta} -> meta.audience == [{"org", "security"}] end)

    assert {:ok, []} =
             Mnemosyne.get_linked_nodes(ctx.repo, receipt.node_ids,
               supervisor: ctx.sup,
               authorization: auth()
             )
  end

  test "opening labeled memories without access control fails closed", ctx do
    assert {:error, _} = open(ctx, access_control: false)
  end

  test "raw graph export is unavailable for access-controlled repos", ctx do
    assert {:ok, _} = open(ctx)

    assert {:error, _} =
             Mnemosyne.get_graph(ctx.repo,
               supervisor: ctx.sup,
               authorization: auth([{"org", "security"}])
             )
  end
end
