defmodule Mnemosyne.MemoryStoreTest do
  use ExUnit.Case, async: false
  use AssertEventually, timeout: 500, interval: 10

  import Mimic

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.Errors.Framework.PipelineError
  alias Mnemosyne.Errors.Framework.StorageError
  alias Mnemosyne.Errors.Invalid.IngestionError
  alias Mnemosyne.Graph
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Intent
  alias Mnemosyne.Graph.Node.Procedural
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Tag
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.GraphBackends.Persistence.DETS
  alias Mnemosyne.IngestionReceipt
  alias Mnemosyne.LLM
  alias Mnemosyne.MemoryStore
  alias Mnemosyne.NodeMetadata
  alias Mnemosyne.Pipeline.Ingestion
  alias Mnemosyne.Pipeline.Reasoning.ReasonedMemory
  alias Mnemosyne.Pipeline.RecallResult
  alias Mnemosyne.Trajectory

  @moduletag :tmp_dir

  setup :set_mimic_global

  defp build_config do
    {:ok, config} =
      Zoi.parse(Config.t(), %{
        llm: %{model: "test-model", opts: %{}},
        embedding: %{model: "test-embed", opts: %{}}
      })

    config
  end

  defp unique_name, do: :"memory_store_#{System.unique_integer([:positive])}"

  defp start_store(tmp_dir, opts \\ []) do
    dets_path = Path.join(tmp_dir, "test_store.dets")
    persistence = {DETS, path: dets_path}
    task_sup = :"task_sup_#{System.unique_integer([:positive])}"
    name = Keyword.get_lazy(opts, :name, &unique_name/0)
    start_supervised!({Task.Supervisor, name: task_sup})

    store_opts =
      Keyword.merge(
        [
          name: name,
          backend: {InMemory, persistence: persistence},
          config: build_config(),
          llm: Mnemosyne.MockLLM,
          embedding: Mnemosyne.MockEmbedding,
          task_supervisor: task_sup
        ],
        opts
      )

    start_supervised!({MemoryStore, store_opts}, id: name)
  end

  defp pre_populate_dets(tmp_dir) do
    dets_path = Path.join(tmp_dir, "test_store.dets")
    {:ok, state} = DETS.init(path: dets_path)
    node = %Semantic{id: "pre-1", proposition: "Preloaded fact", confidence: 0.8}
    changeset = Changeset.add_node(Changeset.new(), node)
    :ok = DETS.save(changeset, state)
    :dets.close(state.ref)
  end

  defp make_semantic(id, proposition) do
    %Semantic{id: id, proposition: proposition, confidence: 0.9}
  end

  def chat_structured(_messages, _schema, opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    send(test_pid, {:override_llm_used, opts})

    {:ok,
     %LLM.Response{
       content: %{merged_intent: "Merged by override"},
       model: "override-llm",
       usage: %{}
     }}
  end

  def embed_batch(["Merged by override"], opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    send(test_pid, {:override_embedding_used, opts})

    {:ok,
     %Embedding.Response{
       vectors: [[0.88, 0.12]],
       model: "override-embedding",
       usage: %{}
     }}
  end

  def score(_relevance, _node, _metadata, %{test_pid: test_pid}) do
    send(test_pid, :override_value_function_used)
    0.88
  end

  defp trajectory(overrides \\ []) do
    struct!(
      Trajectory,
      Keyword.merge(
        [
          source_id: "source-1",
          goal: "Diagnose timeouts",
          steps: [%{observation: "Timeout", action: "Inspect logs"}],
          metadata: %{}
        ],
        overrides
      )
    )
  end

  defp extraction_gate(test_pid) do
    stub(Ingestion, :run, fn trajectory, opts ->
      send(test_pid, {:extraction_started, trajectory.source_id, self(), opts})

      receive do
        {:finish_extraction, result} -> result
      end
    end)
  end

  defp start_ingest(store, trajectory, opts \\ []) do
    Task.async(fn -> MemoryStore.ingest(store, trajectory, opts) end)
  end

  defp enqueue_ingest(store, trajectory, opts \\ []) do
    {:ok, digest} = Ingestion.prepare(trajectory)
    tag = make_ref()
    send(store, {:"$gen_call", {self(), tag}, {:ingest, trajectory, digest, opts}})
    MemoryStore.get_graph(store)
    tag
  end

  describe "ingest/3" do
    test "prepares before the store and passes execution overrides to extraction", %{
      tmp_dir: tmp_dir
    } do
      test_pid = self()
      node = make_semantic("ingested-1", "Stored fact")
      changeset = Changeset.add_node(Changeset.new(), node)
      override_config = %{build_config() | llm: %{model: "override", opts: %{}}}

      stub(Ingestion, :run, fn _trajectory, opts ->
        send(test_pid, {:execution_opts, opts})
        {:ok, changeset}
      end)

      pid = start_store(tmp_dir, repo_id: "repo-1")

      assert {:error, %IngestionError{reason: :invalid_goal}} =
               MemoryStore.ingest(:missing_store, trajectory(goal: " "))

      assert {:ok, %IngestionReceipt{} = receipt} =
               MemoryStore.ingest(pid, trajectory(),
                 config: override_config,
                 llm: __MODULE__,
                 embedding: __MODULE__,
                 llm_opts: [temperature: 0.0]
               )

      assert_receive {:execution_opts, opts}
      assert opts[:config] == override_config
      assert opts[:llm] == __MODULE__
      assert opts[:embedding] == __MODULE__
      assert opts[:llm_opts] == [temperature: 0.0]
      assert opts[:repo_id] == "repo-1"
      assert receipt.source_id == "source-1"
      assert receipt.node_ids == ["ingested-1"]
      assert %Semantic{} = Graph.get_node(MemoryStore.get_graph(pid), "ingested-1")
    end

    test "uses first-admitted execution overrides for write-time intent merging", %{
      tmp_dir: tmp_dir
    } do
      test_pid = self()
      pid = start_store(tmp_dir, repo_id: "override-repo")

      existing_intent = %Intent{
        id: "intent-existing",
        description: "Existing intent",
        embedding: [1.0, 0.0]
      }

      :ok =
        MemoryStore.apply_changeset(
          pid,
          Changeset.add_node(Changeset.new(), existing_intent)
        )

      assert_eventually(%Intent{} = Graph.get_node(MemoryStore.get_graph(pid), "intent-existing"))

      extraction_gate(test_pid)

      override_config = %{
        build_config()
        | llm: %{model: "override-llm", opts: %{config_llm_opt: true}},
          embedding: %{
            model: "override-embedding",
            opts: %{config_embedding_opt: true}
          },
          value_function: %{
            module: __MODULE__,
            params: %{
              intent: %{test_pid: test_pid, threshold: 0.0, top_k: 20}
            }
          }
      }

      handler_id = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach(
          handler_id,
          [:mnemosyne, :intent_merger, :merge, :start],
          fn _event, _measurements, metadata, pid ->
            send(pid, {:intent_merge_metadata, metadata})
          end,
          test_pid
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      input = trajectory(source_id: "write-options")

      first =
        start_ingest(pid, input,
          config: override_config,
          llm: __MODULE__,
          embedding: __MODULE__,
          llm_opts: [test_pid: test_pid, caller_llm_opt: true],
          embedding_opts: [test_pid: test_pid, caller_embedding_opt: true]
        )

      assert_receive {:extraction_started, "write-options", worker, extraction_opts}
      assert extraction_opts[:config] == override_config

      second_tag =
        enqueue_ingest(pid, input,
          config: build_config(),
          llm: :second_caller_llm,
          embedding: :second_caller_embedding
        )

      changeset =
        Changeset.new()
        |> Changeset.add_node(%Intent{
          id: "intent-new",
          description: "New intent",
          embedding: [1.0, 0.0]
        })
        |> Changeset.add_node(%Procedural{
          id: "procedure-new",
          instruction: "Do it",
          condition: "When needed",
          expected_outcome: "Done",
          embedding: [0.5, 0.5]
        })
        |> Changeset.add_link("intent-new", "procedure-new", :hierarchical)

      send(worker, {:finish_extraction, {:ok, changeset}})

      assert {:ok, receipt} = Task.await(first)
      assert_receive {^second_tag, {:ok, ^receipt}}
      assert_receive :override_value_function_used
      assert_receive {:override_llm_used, llm_opts}
      assert_receive {:override_embedding_used, embedding_opts}
      assert_receive {:intent_merge_metadata, %{repo_id: "override-repo"}}

      assert llm_opts[:model] == "override-llm"
      assert llm_opts[:config_llm_opt]
      assert llm_opts[:caller_llm_opt]
      assert embedding_opts[:model] == "override-embedding"
      assert embedding_opts[:config_embedding_opt]
      assert embedding_opts[:caller_embedding_opt]

      assert %Intent{description: "Merged by override"} =
               Graph.get_node(MemoryStore.get_graph(pid), "intent-existing")
    end

    test "coalesces an equal pending source and rejects a conflicting payload", %{
      tmp_dir: tmp_dir
    } do
      test_pid = self()
      extraction_gate(test_pid)
      pid = start_store(tmp_dir)
      input = trajectory()
      changeset = Changeset.add_node(Changeset.new(), make_semantic("single", "Single"))

      first = start_ingest(pid, input)
      assert_receive {:extraction_started, "source-1", worker, _opts}
      second_tag = enqueue_ingest(pid, input)

      assert {:error, %IngestionError{reason: :source_conflict}} =
               MemoryStore.ingest(pid, trajectory(goal: "Different goal"))

      send(worker, {:finish_extraction, {:ok, changeset}})
      assert {:ok, first_receipt} = Task.await(first)
      assert_receive {^second_tag, {:ok, ^first_receipt}}
      refute_receive {:extraction_started, "source-1", _worker, _opts}
    end

    test "extracts different source IDs concurrently", %{tmp_dir: tmp_dir} do
      test_pid = self()
      extraction_gate(test_pid)
      pid = start_store(tmp_dir)

      first = start_ingest(pid, trajectory(source_id: "source-a"))
      assert_receive {:extraction_started, "source-a", worker_a, _opts}

      second = start_ingest(pid, trajectory(source_id: "source-b"))
      assert_receive {:extraction_started, "source-b", worker_b, _opts}

      send(
        worker_a,
        {:finish_extraction, {:ok, Changeset.add_node(Changeset.new(), make_semantic("a", "A"))}}
      )

      send(
        worker_b,
        {:finish_extraction, {:ok, Changeset.add_node(Changeset.new(), make_semantic("b", "B"))}}
      )

      assert {:ok, %IngestionReceipt{source_id: "source-a"}} = Task.await(first)
      assert {:ok, %IngestionReceipt{source_id: "source-b"}} = Task.await(second)
    end

    test "propagates one extraction failure to joined callers and allows retry", %{
      tmp_dir: tmp_dir
    } do
      test_pid = self()
      extraction_gate(test_pid)
      pid = start_store(tmp_dir)
      input = trajectory()

      first = start_ingest(pid, input)
      assert_receive {:extraction_started, "source-1", worker, _opts}
      second_tag = enqueue_ingest(pid, input)
      send(worker, {:finish_extraction, {:error, :extraction_failed}})

      assert {:error, :extraction_failed} = Task.await(first)
      assert_receive {^second_tag, {:error, :extraction_failed}}

      retry = start_ingest(pid, input)
      assert_receive {:extraction_started, "source-1", retry_worker, _opts}

      send(
        retry_worker,
        {:finish_extraction,
         {:ok, Changeset.add_node(Changeset.new(), make_semantic("retry", "Retry"))}}
      )

      assert {:ok, %IngestionReceipt{node_ids: ["retry"]}} = Task.await(retry)
    end

    test "normalizes an extraction task crash and clears the source for retry", %{
      tmp_dir: tmp_dir
    } do
      stub(Ingestion, :run, fn _trajectory, _opts -> raise "boom" end)
      pid = start_store(tmp_dir)

      assert {:error, %PipelineError{reason: {:task_crashed, {%RuntimeError{}, _stack}}}} =
               MemoryStore.ingest(pid, trajectory())

      changeset = Changeset.add_node(Changeset.new(), make_semantic("retry", "Retry"))
      stub(Ingestion, :run, fn _trajectory, _opts -> {:ok, changeset} end)
      assert {:ok, %IngestionReceipt{node_ids: ["retry"]}} = MemoryStore.ingest(pid, trajectory())
    end

    test "continues shared ingestion after its caller dies", %{tmp_dir: tmp_dir} do
      test_pid = self()
      extraction_gate(test_pid)
      pid = start_store(tmp_dir)
      input = trajectory()
      caller = spawn(fn -> MemoryStore.ingest(pid, input) end)
      caller_monitor = Process.monitor(caller)

      assert_receive {:extraction_started, "source-1", worker, _opts}
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}

      send(
        worker,
        {:finish_extraction,
         {:ok, Changeset.add_node(Changeset.new(), make_semantic("survivor", "Survivor"))}}
      )

      retry = start_ingest(pid, input)
      assert {:ok, %IngestionReceipt{node_ids: ["survivor"]}} = Task.await(retry)
      assert Process.alive?(pid)
      refute_receive {:extraction_started, "source-1", _worker, _opts}
    end

    test "returns the exact persisted receipt after restart without extraction", %{
      tmp_dir: tmp_dir
    } do
      test_pid = self()
      changeset = Changeset.add_node(Changeset.new(), make_semantic("stored", "Stored"))

      stub(Ingestion, :run, fn _trajectory, _opts ->
        send(test_pid, :extraction_called)
        {:ok, changeset}
      end)

      name1 = unique_name()
      pid = start_store(tmp_dir, name: name1)
      assert {:ok, receipt} = MemoryStore.ingest(pid, trajectory())
      assert_receive :extraction_called
      stop_supervised!(name1)

      pid2 = start_store(tmp_dir, name: unique_name())
      assert {:ok, ^receipt} = MemoryStore.ingest(pid2, trajectory())

      assert {:error, %IngestionError{reason: :source_conflict}} =
               MemoryStore.ingest(pid2, trajectory(goal: "Different goal"))

      refute_receive :extraction_called
    end

    test "builds receipt IDs from the final tag-deduplicated changeset", %{tmp_dir: tmp_dir} do
      first_changeset =
        Changeset.new()
        |> Changeset.add_node(make_semantic("sem-1", "First"))
        |> Changeset.add_node(%Tag{id: "tag-1", label: "database"})
        |> Changeset.add_link("tag-1", "sem-1", :membership)

      second_changeset =
        Changeset.new()
        |> Changeset.add_node(make_semantic("sem-2", "Second"))
        |> Changeset.add_node(%Tag{id: "tag-duplicate", label: "Database"})
        |> Changeset.add_link("tag-duplicate", "sem-2", :membership)

      stub(Ingestion, :run, fn trajectory, _opts ->
        case trajectory.source_id do
          "source-1" -> {:ok, first_changeset}
          "source-2" -> {:ok, second_changeset}
        end
      end)

      pid = start_store(tmp_dir)
      assert {:ok, _receipt} = MemoryStore.ingest(pid, trajectory())

      assert {:ok, %IngestionReceipt{node_ids: ["sem-2"]}} =
               MemoryStore.ingest(pid, trajectory(source_id: "source-2"))

      graph = MemoryStore.get_graph(pid)
      assert [%Tag{id: "tag-1"} = tag] = Graph.nodes_by_type(graph, :tag)
      assert MapSet.member?(tag.links.membership, "sem-2")
    end

    test "does not reply before commit and exposes the graph on return", %{tmp_dir: tmp_dir} do
      test_pid = self()
      changeset = Changeset.add_node(Changeset.new(), make_semantic("committed", "Committed"))
      stub(Ingestion, :run, fn _trajectory, _opts -> {:ok, changeset} end)

      expect(InMemory, :commit_ingestion, fn record, final_changeset, backend_state ->
        send(test_pid, {:commit_started, self()})

        receive do
          :allow_commit ->
            Mimic.call_original(InMemory, :commit_ingestion, [
              record,
              final_changeset,
              backend_state
            ])
        end
      end)

      pid = start_store(tmp_dir)
      caller = start_ingest(pid, trajectory())
      assert_receive {:commit_started, commit_owner}
      assert Task.yield(caller, 0) == nil
      send(commit_owner, :allow_commit)

      assert {:ok, %IngestionReceipt{node_ids: ["committed"]}} = Task.await(caller)
      assert %Semantic{} = Graph.get_node(MemoryStore.get_graph(pid), "committed")
    end

    test "propagates backend read errors to joined callers and allows retry", %{
      tmp_dir: tmp_dir
    } do
      test_pid = self()

      changeset =
        Changeset.new()
        |> Changeset.add_node(make_semantic("read-error-node", "Must not leak"))
        |> Changeset.add_node(%Tag{id: "read-error-tag", label: "backend-read"})

      error =
        {:error,
         StorageError.exception(operation: :get_nodes_by_type, reason: :temporarily_unavailable)}

      stub(Ingestion, :run, fn _trajectory, _opts ->
        send(test_pid, :extraction_called)
        {:ok, changeset}
      end)

      stub(InMemory, :get_nodes_by_type, fn types, backend_state ->
        if types == [:tag] do
          send(test_pid, {:backend_read_started, self()})

          receive do
            :fail_backend_read ->
              error

            :allow_backend_read ->
              Mimic.call_original(InMemory, :get_nodes_by_type, [types, backend_state])
          end
        else
          Mimic.call_original(InMemory, :get_nodes_by_type, [types, backend_state])
        end
      end)

      pid = start_store(tmp_dir)
      first = start_ingest(pid, trajectory())
      assert_receive :extraction_called
      assert_receive {:backend_read_started, read_worker}
      second_tag = enqueue_ingest(pid, trajectory())
      send(read_worker, :fail_backend_read)

      assert ^error = Task.await(first)
      assert_receive {^second_tag, ^error}
      assert Graph.get_node(MemoryStore.get_graph(pid), "read-error-node") == nil

      retry = start_ingest(pid, trajectory())
      assert_receive :extraction_called
      assert_receive {:backend_read_started, retry_worker}
      send(retry_worker, :allow_backend_read)

      assert {:ok, %IngestionReceipt{}} = Task.await(retry)
      assert %Semantic{} = Graph.get_node(MemoryStore.get_graph(pid), "read-error-node")
    end

    test "propagates storage errors to joined callers and clears pending state", %{
      tmp_dir: tmp_dir
    } do
      test_pid = self()

      changeset =
        Changeset.new()
        |> Changeset.add_node(make_semantic("unstored", "Unstored"))
        |> Changeset.add_node(%Tag{id: "unstored-tag", label: "unstored"})

      error = {:error, StorageError.exception(operation: :commit_ingestion, reason: :disk_full)}

      stub(Ingestion, :run, fn _trajectory, _opts ->
        send(test_pid, :extraction_called)
        {:ok, changeset}
      end)

      stub(InMemory, :get_nodes_by_type, fn types, backend_state ->
        if types == [:tag] do
          send(test_pid, {:write_started, self()})

          receive do
            :continue_write -> :ok
          end
        end

        Mimic.call_original(InMemory, :get_nodes_by_type, [types, backend_state])
      end)

      stub(InMemory, :commit_ingestion, fn _record, _changeset, _backend_state -> error end)

      pid = start_store(tmp_dir)
      first = start_ingest(pid, trajectory())
      assert_receive :extraction_called
      assert_receive {:write_started, write_worker}
      second_tag = enqueue_ingest(pid, trajectory())
      send(write_worker, :continue_write)

      assert ^error = Task.await(first)
      assert_receive {^second_tag, ^error}

      retry = start_ingest(pid, trajectory())
      assert_receive :extraction_called
      assert_receive {:write_started, retry_write_worker}
      send(retry_write_worker, :continue_write)
      assert ^error = Task.await(retry)
      assert Graph.get_node(MemoryStore.get_graph(pid), "unstored") == nil
    end

    test "returns the original receipt from an equal late backend compare-and-set", %{
      tmp_dir: tmp_dir
    } do
      supplied = Changeset.add_node(Changeset.new(), make_semantic("supplied", "Supplied"))
      authoritative = Changeset.add_node(Changeset.new(), make_semantic("winner", "Winner"))
      stored_at = ~U[2026-08-25 12:00:00Z]

      original_receipt = %IngestionReceipt{
        source_id: "source-1",
        node_ids: ["winner"],
        stored_at: stored_at
      }

      stub(Ingestion, :run, fn _trajectory, _opts -> {:ok, supplied} end)

      expect(InMemory, :commit_ingestion, fn record, changeset, backend_state ->
        prior_record = %{record | receipt: original_receipt}

        {:ok, :inserted, ^original_receipt, raced_state} =
          Mimic.call_original(InMemory, :commit_ingestion, [
            prior_record,
            authoritative,
            backend_state
          ])

        Mimic.call_original(InMemory, :commit_ingestion, [record, changeset, raced_state])
      end)

      pid = start_store(tmp_dir)
      assert {:ok, ^original_receipt} = MemoryStore.ingest(pid, trajectory())
      graph = MemoryStore.get_graph(pid)
      assert %Semantic{} = Graph.get_node(graph, "winner")
      assert Graph.get_node(graph, "supplied") == nil
    end
  end

  describe "init with empty DETS" do
    test "starts with an empty graph", %{tmp_dir: tmp_dir} do
      pid = start_store(tmp_dir)

      graph = MemoryStore.get_graph(pid)
      assert graph.nodes == %{}
    end
  end

  describe "init with pre-populated DETS" do
    test "loads existing nodes from storage", %{tmp_dir: tmp_dir} do
      pre_populate_dets(tmp_dir)
      pid = start_store(tmp_dir)

      graph = MemoryStore.get_graph(pid)
      assert %Semantic{proposition: "Preloaded fact"} = Graph.get_node(graph, "pre-1")
    end
  end

  describe "apply_changeset/2" do
    test "updates graph and persists to storage", %{tmp_dir: tmp_dir} do
      pid = start_store(tmp_dir)

      node = make_semantic("s1", "Test fact")
      changeset = Changeset.add_node(Changeset.new(), node)

      assert :ok = MemoryStore.apply_changeset(pid, changeset)

      assert_eventually(
        %Semantic{proposition: "Test fact"} = Graph.get_node(MemoryStore.get_graph(pid), "s1")
      )
    end

    test "persists changes to DETS so they survive reload", %{tmp_dir: tmp_dir} do
      name1 = unique_name()
      pid = start_store(tmp_dir, name: name1)

      node = make_semantic("s2", "Persistent fact")
      changeset = Changeset.add_node(Changeset.new(), node)
      :ok = MemoryStore.apply_changeset(pid, changeset)

      assert_eventually(Graph.get_node(MemoryStore.get_graph(pid), "s2") != nil)

      stop_supervised!(name1)

      name2 = unique_name()
      pid2 = start_store(tmp_dir, name: name2)
      graph = MemoryStore.get_graph(pid2)
      assert %Semantic{proposition: "Persistent fact"} = Graph.get_node(graph, "s2")
    end

    test "serializes multiple concurrent changesets", %{tmp_dir: tmp_dir} do
      pid = start_store(tmp_dir)

      for i <- 1..5 do
        node = make_semantic("batch-#{i}", "Fact #{i}")
        changeset = Changeset.add_node(Changeset.new(), node)
        :ok = MemoryStore.apply_changeset(pid, changeset)
      end

      assert_eventually(
        Enum.all?(1..5, fn i ->
          Graph.get_node(MemoryStore.get_graph(pid), "batch-#{i}") != nil
        end)
      )
    end
  end

  describe "get_graph/1" do
    test "returns current graph state", %{tmp_dir: tmp_dir} do
      pid = start_store(tmp_dir)
      assert %Graph{} = MemoryStore.get_graph(pid)
    end
  end

  describe "delete_nodes/2" do
    test "removes nodes from graph and storage", %{tmp_dir: tmp_dir} do
      pid = start_store(tmp_dir)

      node = make_semantic("del-1", "To delete")
      changeset = Changeset.add_node(Changeset.new(), node)
      :ok = MemoryStore.apply_changeset(pid, changeset)

      assert_eventually(Graph.get_node(MemoryStore.get_graph(pid), "del-1") != nil)

      assert :ok = MemoryStore.delete_nodes(pid, ["del-1"])

      assert_eventually(Graph.get_node(MemoryStore.get_graph(pid), "del-1") == nil)
    end
  end

  describe "recall/3" do
    test "runs retrieval and reasoning pipeline, returns ReasonedMemory", %{tmp_dir: tmp_dir} do
      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        {:ok, %LLM.Response{content: "semantic", model: "test", usage: %{}}}
      end)

      stub(Mnemosyne.MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        {:ok,
         %LLM.Response{
           content: %{reasoning: "analysis", information: "Summary."},
           model: "test",
           usage: %{}
         }}
      end)

      stub(Mnemosyne.MockEmbedding, :embed, fn _text, _opts ->
        {:ok, %Embedding.Response{vectors: [List.duplicate(0.1, 128)], model: "test", usage: %{}}}
      end)

      stub(Mnemosyne.MockEmbedding, :embed_batch, fn texts, _opts ->
        vectors = Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)
        {:ok, %Embedding.Response{vectors: vectors, model: "test", usage: %{}}}
      end)

      pid = start_store(tmp_dir)

      node = make_semantic("s1", "Elixir is functional")
      tag = %Tag{id: "t1", label: "elixir"}

      changeset =
        Changeset.new()
        |> Changeset.add_node(node)
        |> Changeset.add_node(tag)

      :ok = MemoryStore.apply_changeset(pid, changeset)

      assert_eventually(Graph.get_node(MemoryStore.get_graph(pid), "s1") != nil)

      assert {:ok, %RecallResult{reasoned: %ReasonedMemory{}}} =
               MemoryStore.recall(pid, "what is elixir?")
    end

    test "recall result includes touched_nodes and trace", %{tmp_dir: tmp_dir} do
      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        {:ok, %LLM.Response{content: "semantic", model: "test", usage: %{}}}
      end)

      stub(Mnemosyne.MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        {:ok,
         %LLM.Response{
           content: %{reasoning: "analysis", information: "Summary."},
           model: "test",
           usage: %{}
         }}
      end)

      stub(Mnemosyne.MockEmbedding, :embed, fn _text, _opts ->
        {:ok, %Embedding.Response{vectors: [List.duplicate(0.1, 128)], model: "test", usage: %{}}}
      end)

      stub(Mnemosyne.MockEmbedding, :embed_batch, fn texts, _opts ->
        vectors = Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)
        {:ok, %Embedding.Response{vectors: vectors, model: "test", usage: %{}}}
      end)

      pid = start_store(tmp_dir)

      node = make_semantic("s1", "Elixir is functional")
      tag = %Tag{id: "t1", label: "elixir"}

      changeset =
        Changeset.new()
        |> Changeset.add_node(node)
        |> Changeset.add_node(tag)

      :ok = MemoryStore.apply_changeset(pid, changeset)
      assert_eventually(Graph.get_node(MemoryStore.get_graph(pid), "s1") != nil)

      assert {:ok, %RecallResult{touched_nodes: touched, trace: trace}} =
               MemoryStore.recall(pid, "what is elixir?")

      assert is_list(touched)
      assert trace.phase_timings != nil
      assert trace.candidates_per_hop != nil
      assert trace.scores != nil
    end

    test "formats an empty context without lookup, persistence, or source reservation", %{
      tmp_dir: tmp_dir
    } do
      test_pid = self()

      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        {:ok, %LLM.Response{content: "semantic", model: "test", usage: %{}}}
      end)

      stub(Mnemosyne.MockEmbedding, :embed, fn text, _opts ->
        send(test_pid, {:retrieval_query, text})
        {:ok, %Embedding.Response{vectors: [List.duplicate(0.1, 128)], model: "test", usage: %{}}}
      end)

      stub(Mnemosyne.MockEmbedding, :embed_batch, fn texts, _opts ->
        vectors = Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)
        {:ok, %Embedding.Response{vectors: vectors, model: "test", usage: %{}}}
      end)

      pid = start_store(tmp_dir)
      state_before = :sys.get_state(pid)
      context = %{goal: "Diagnose timeouts", recent_steps: []}

      assert {:ok, %RecallResult{}} =
               MemoryStore.recall(pid, "What next?",
                 context: context,
                 source_id: "missing-session",
                 max_hops: 0
               )

      assert_received {:retrieval_query, "Goal: Diagnose timeouts\n\nQuery: What next?"}

      state_after = :sys.get_state(pid)
      {InMemory, backend_before} = state_before.backend
      {InMemory, backend_after} = state_after.backend

      assert backend_after.graph == backend_before.graph
      assert backend_after.metadata == backend_before.metadata
      assert backend_after.ingestions == backend_before.ingestions
      assert state_after.write_active == state_before.write_active
      assert state_after.write_queue == state_before.write_queue
      assert state_after.pending_recalls == %{}

      node = make_semantic("later-ingestion", "Recall did not reserve this source")

      stub(Ingestion, :run, fn _trajectory, _opts ->
        {:ok, Changeset.add_node(Changeset.new(), node)}
      end)

      assert {:ok, %IngestionReceipt{source_id: "missing-session"}} =
               MemoryStore.ingest(pid, trajectory(source_id: "missing-session"))
    end

    test "rejects every malformed step before contacting the store", %{tmp_dir: tmp_dir} do
      pid = start_store(tmp_dir)

      valid_steps = [
        %{observation: "Second", action: "Act two"},
        %{observation: "Third", action: "Act three"},
        %{observation: "Fourth", action: "Act four"}
      ]

      malformed_contexts = [
        %{goal: "Goal", recent_steps: valid_steps ++ [%{observation: "Malformed"}]},
        %{goal: "Goal", recent_steps: [%{observation: "Malformed"} | valid_steps]}
      ]

      for context <- malformed_contexts do
        assert_raise FunctionClauseError, fn ->
          MemoryStore.recall(pid, "Query", context: context, max_hops: 0)
        end

        assert Process.alive?(pid)
        assert :sys.get_state(pid).pending_recalls == %{}
        assert %Graph{nodes: %{}} = MemoryStore.get_graph(pid)
      end
    end
  end

  describe "recall task crash" do
    test "returns error to caller when task crashes", %{tmp_dir: tmp_dir} do
      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        raise "boom"
      end)

      stub(Mnemosyne.MockEmbedding, :embed, fn _text, _opts ->
        raise "boom"
      end)

      stub(Mnemosyne.MockEmbedding, :embed_batch, fn _texts, _opts ->
        raise "boom"
      end)

      pid = start_store(tmp_dir)

      assert {:error, _reason} =
               MemoryStore.recall(pid, "crash query", source_id: "crashed-source")

      assert :sys.get_state(pid).pending_recalls == %{}
    end
  end

  describe "consolidate_semantics/2" do
    test "consolidates near-duplicate semantic nodes", %{tmp_dir: tmp_dir} do
      stub(Mnemosyne.MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        {:ok,
         %LLM.Response{
           content: %{merged_statement: "Elixir is great", relationship: "SAME_TOPIC_MERGE_WELL"},
           model: "mock:test",
           usage: %{}
         }}
      end)

      pid = start_store(tmp_dir)

      emb = List.duplicate(0.5, 128)
      emb_similar = List.duplicate(0.5, 127) ++ [0.50001]

      tag = %Tag{id: "t1", label: "elixir", links: %{membership: MapSet.new(["s1", "s2"])}}

      sem1 = %Semantic{
        id: "s1",
        proposition: "Elixir is great",
        confidence: 0.9,
        embedding: emb,
        links: %{membership: MapSet.new(["t1"])}
      }

      sem2 = %Semantic{
        id: "s2",
        proposition: "Elixir is awesome",
        confidence: 0.9,
        embedding: emb_similar,
        links: %{membership: MapSet.new(["t1"])}
      }

      meta1 = NodeMetadata.new(created_at: DateTime.utc_now(), access_count: 5)
      meta2 = NodeMetadata.new(created_at: DateTime.utc_now(), access_count: 0)

      changeset =
        Changeset.new()
        |> Changeset.add_node(tag)
        |> Changeset.add_node(sem1)
        |> Changeset.add_node(sem2)
        |> Changeset.put_metadata("s1", meta1)
        |> Changeset.put_metadata("s2", meta2)

      :ok = MemoryStore.apply_changeset(pid, changeset)

      assert_eventually(length(Graph.nodes_by_type(MemoryStore.get_graph(pid), :semantic)) == 2)

      :ok = MemoryStore.consolidate_semantics(pid)

      assert_eventually(length(Graph.nodes_by_type(MemoryStore.get_graph(pid), :semantic)) == 1)
    end

    test "handles empty graph without error", %{tmp_dir: tmp_dir} do
      pid = start_store(tmp_dir)

      :ok = MemoryStore.consolidate_semantics(pid)
      assert %Graph{} = MemoryStore.get_graph(pid)
    end

    test "accepts concurrent requests without crashing", %{tmp_dir: tmp_dir} do
      pid = start_store(tmp_dir)

      :ok = MemoryStore.consolidate_semantics(pid)
      :ok = MemoryStore.consolidate_semantics(pid)
      assert %Graph{} = MemoryStore.get_graph(pid)
    end
  end

  describe "decay_nodes/2" do
    test "prunes low-utility nodes", %{tmp_dir: tmp_dir} do
      pid = start_store(tmp_dir)

      old_time = ~U[2020-01-01 00:00:00Z]
      emb = List.duplicate(0.5, 128)

      sem = %Semantic{id: "s-old", proposition: "Stale fact", confidence: 0.9, embedding: emb}
      meta = NodeMetadata.new(created_at: old_time, access_count: 0)

      changeset =
        Changeset.new()
        |> Changeset.add_node(sem)
        |> Changeset.put_metadata("s-old", meta)

      :ok = MemoryStore.apply_changeset(pid, changeset)

      assert_eventually(Graph.get_node(MemoryStore.get_graph(pid), "s-old") != nil)

      :ok = MemoryStore.decay_nodes(pid)

      assert_eventually(Graph.get_node(MemoryStore.get_graph(pid), "s-old") == nil)
    end

    test "handles empty graph without error", %{tmp_dir: tmp_dir} do
      pid = start_store(tmp_dir)

      :ok = MemoryStore.decay_nodes(pid)
      assert %Graph{} = MemoryStore.get_graph(pid)
    end

    test "state persists after maintenance", %{tmp_dir: tmp_dir} do
      pid = start_store(tmp_dir)

      old_time = ~U[2020-01-01 00:00:00Z]
      emb = List.duplicate(0.5, 128)

      sem = %Semantic{
        id: "s-persist",
        proposition: "Will be pruned",
        confidence: 0.9,
        embedding: emb
      }

      meta = NodeMetadata.new(created_at: old_time, access_count: 0)

      changeset =
        Changeset.new()
        |> Changeset.add_node(sem)
        |> Changeset.put_metadata("s-persist", meta)

      :ok = MemoryStore.apply_changeset(pid, changeset)

      assert_eventually(Graph.get_node(MemoryStore.get_graph(pid), "s-persist") != nil)

      :ok = MemoryStore.decay_nodes(pid)

      assert_eventually(Graph.get_node(MemoryStore.get_graph(pid), "s-persist") == nil)
    end
  end

  describe "concurrent lanes" do
    test "write and maintenance can run simultaneously", %{tmp_dir: tmp_dir} do
      pid = start_store(tmp_dir)

      old_time = ~U[2020-01-01 00:00:00Z]
      emb = List.duplicate(0.5, 128)

      stale = %Semantic{id: "stale-1", proposition: "Stale", confidence: 0.9, embedding: emb}
      stale_meta = NodeMetadata.new(created_at: old_time, access_count: 0)

      stale_cs =
        Changeset.new()
        |> Changeset.add_node(stale)
        |> Changeset.put_metadata("stale-1", stale_meta)

      :ok = MemoryStore.apply_changeset(pid, stale_cs)

      assert_eventually(Graph.get_node(MemoryStore.get_graph(pid), "stale-1") != nil)

      # Fire both lanes at once: maintenance (decay) and write (add node)
      :ok = MemoryStore.decay_nodes(pid)
      new_node = make_semantic("new-1", "Fresh fact")
      :ok = MemoryStore.apply_changeset(pid, Changeset.add_node(Changeset.new(), new_node))

      assert_eventually(Graph.get_node(MemoryStore.get_graph(pid), "stale-1") == nil)

      # Verify the store is still functional by issuing a new write
      fresh_node = make_semantic("new-2", "Post-maintenance fact")
      :ok = MemoryStore.apply_changeset(pid, Changeset.add_node(Changeset.new(), fresh_node))

      assert_eventually(
        %Semantic{proposition: "Post-maintenance fact"} =
          Graph.get_node(MemoryStore.get_graph(pid), "new-2")
      )
    end
  end

  describe "recall_in_context/4" do
    test "falls back to raw query when Session module is unavailable", %{tmp_dir: tmp_dir} do
      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        {:ok, %LLM.Response{content: "semantic", model: "test", usage: %{}}}
      end)

      stub(Mnemosyne.MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        {:ok,
         %LLM.Response{
           content: %{reasoning: "analysis", information: "Summary."},
           model: "test",
           usage: %{}
         }}
      end)

      stub(Mnemosyne.MockEmbedding, :embed, fn _text, _opts ->
        {:ok, %Embedding.Response{vectors: [List.duplicate(0.1, 128)], model: "test", usage: %{}}}
      end)

      stub(Mnemosyne.MockEmbedding, :embed_batch, fn texts, _opts ->
        vectors = Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)
        {:ok, %Embedding.Response{vectors: vectors, model: "test", usage: %{}}}
      end)

      pid = start_store(tmp_dir)

      node = make_semantic("s1", "Elixir is functional")

      changeset =
        Changeset.add_node(Changeset.new(), node)

      :ok = MemoryStore.apply_changeset(pid, changeset)

      assert_eventually(Graph.get_node(MemoryStore.get_graph(pid), "s1") != nil)

      assert {:ok, %RecallResult{reasoned: %ReasonedMemory{}}} =
               MemoryStore.recall_in_context(pid, "nonexistent-session", "what is elixir?")
    end
  end

  describe "tag deduplication in write lane" do
    test "deduplicates tags with different casing across changesets", %{tmp_dir: tmp_dir} do
      pid = start_store(tmp_dir)

      sem1 = make_semantic("sem-1", "PostgreSQL uses MVCC")
      tag1 = %Tag{id: "tag-1", label: "database"}

      cs1 =
        Changeset.new()
        |> Changeset.add_node(sem1)
        |> Changeset.add_node(tag1)
        |> Changeset.add_link("tag-1", "sem-1", :membership)

      :ok = MemoryStore.apply_changeset(pid, cs1)
      assert_eventually(Graph.get_node(MemoryStore.get_graph(pid), "sem-1") != nil)

      sem2 = make_semantic("sem-2", "MySQL supports replication")
      tag2 = %Tag{id: "tag-2", label: "Database"}

      cs2 =
        Changeset.new()
        |> Changeset.add_node(sem2)
        |> Changeset.add_node(tag2)
        |> Changeset.add_link("tag-2", "sem-2", :membership)

      :ok = MemoryStore.apply_changeset(pid, cs2)
      assert_eventually(Graph.get_node(MemoryStore.get_graph(pid), "sem-2") != nil)

      graph = MemoryStore.get_graph(pid)
      tags = Graph.nodes_by_type(graph, :tag)
      assert [%Tag{label: "database"}] = tags

      tag = hd(tags)
      tag_member_links = Map.get(tag.links, :membership, MapSet.new())
      assert MapSet.member?(tag_member_links, "sem-1")
      assert MapSet.member?(tag_member_links, "sem-2")
    end
  end

  describe "recall updates access metadata" do
    test "increments access_count for retrieved nodes", %{tmp_dir: tmp_dir} do
      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        {:ok, %LLM.Response{content: "semantic", model: "test", usage: %{}}}
      end)

      stub(Mnemosyne.MockLLM, :chat_structured, fn _messages, _schema, _opts ->
        {:ok,
         %LLM.Response{
           content: %{reasoning: "analysis", information: "Summary."},
           model: "test",
           usage: %{}
         }}
      end)

      stub(Mnemosyne.MockEmbedding, :embed, fn _text, _opts ->
        {:ok, %Embedding.Response{vectors: [List.duplicate(0.1, 128)], model: "test", usage: %{}}}
      end)

      stub(Mnemosyne.MockEmbedding, :embed_batch, fn texts, _opts ->
        vectors = Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)
        {:ok, %Embedding.Response{vectors: vectors, model: "test", usage: %{}}}
      end)

      pid = start_store(tmp_dir)

      node = make_semantic("s1", "Elixir is functional")
      tag = %Tag{id: "t1", label: "elixir"}

      changeset =
        Changeset.new()
        |> Changeset.add_node(node)
        |> Changeset.add_node(tag)
        |> Changeset.add_link("t1", "s1", :membership)
        |> Changeset.put_metadata("s1", NodeMetadata.new())

      :ok = MemoryStore.apply_changeset(pid, changeset)

      assert_eventually(Graph.get_node(MemoryStore.get_graph(pid), "s1") != nil)

      {:ok, %{}} = MemoryStore.get_metadata(pid, ["s1"])

      assert {:ok, %RecallResult{reasoned: %ReasonedMemory{}}} =
               MemoryStore.recall(pid, "what is elixir?")

      assert_eventually(
        match?(
          {:ok, %{"s1" => %NodeMetadata{access_count: 1}}},
          MemoryStore.get_metadata(pid, ["s1"])
        )
      )
    end
  end
end
