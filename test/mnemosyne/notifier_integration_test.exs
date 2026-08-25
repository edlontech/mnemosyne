defmodule Mnemosyne.NotifierIntegrationTest do
  use ExUnit.Case, async: true
  use AssertEventually, timeout: 500, interval: 10

  alias Mnemosyne.Config
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Tag
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.GraphBackends.Persistence.DETS
  alias Mnemosyne.MemoryStore
  alias Mnemosyne.NodeMetadata
  alias Mnemosyne.TestNotifier

  @moduletag :tmp_dir

  setup do
    TestNotifier.setup()
    :ok
  end

  defp build_config do
    {:ok, config} =
      Zoi.parse(Config.t(), %{
        llm: %{model: "test-model", opts: %{}},
        embedding: %{model: "test-embed", opts: %{}}
      })

    config
  end

  defp unique_name, do: :"notifier_int_#{System.unique_integer([:positive])}"

  defp unique_repo_id, do: "repo-#{System.unique_integer([:positive])}"

  defp start_store(tmp_dir, opts) do
    dets_path = Path.join(tmp_dir, "test_store_#{System.unique_integer([:positive])}.dets")
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
          task_supervisor: task_sup,
          notifier: TestNotifier
        ],
        opts
      )

    start_supervised!({MemoryStore, store_opts}, id: name)
  end

  defp make_semantic(id, proposition) do
    %Semantic{id: id, proposition: proposition, confidence: 0.9}
  end

  describe "apply_changeset notification" do
    test "emits {:changeset_applied, changeset, metadata} on success", %{tmp_dir: tmp_dir} do
      repo_id = unique_repo_id()
      pid = start_store(tmp_dir, repo_id: repo_id)
      node = make_semantic("s1", "Test fact")
      changeset = Changeset.add_node(Changeset.new(), node)

      :ok = MemoryStore.apply_changeset(pid, changeset)

      assert_eventually(
        Enum.any?(TestNotifier.events(repo_id), fn
          {:changeset_applied, %Changeset{}, %{}} -> true
          _ -> false
        end)
      )
    end
  end

  describe "delete_nodes notification" do
    test "emits {:nodes_deleted, node_ids, metadata} on success", %{tmp_dir: tmp_dir} do
      repo_id = unique_repo_id()
      pid = start_store(tmp_dir, repo_id: repo_id)
      node = make_semantic("del-1", "To delete")
      changeset = Changeset.add_node(Changeset.new(), node)
      :ok = MemoryStore.apply_changeset(pid, changeset)

      assert_eventually(
        Enum.any?(TestNotifier.events(repo_id), &match?({:changeset_applied, _, %{}}, &1))
      )

      :ok = MemoryStore.delete_nodes(pid, ["del-1"])

      assert_eventually(
        Enum.any?(TestNotifier.events(repo_id), &match?({:nodes_deleted, ["del-1"], %{}}, &1))
      )
    end
  end

  describe "consolidate_semantics notification" do
    test "emits {:consolidation_completed, stats, metadata} on success", %{tmp_dir: tmp_dir} do
      repo_id = unique_repo_id()
      pid = start_store(tmp_dir, repo_id: repo_id)

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

      assert_eventually(
        Enum.any?(TestNotifier.events(repo_id), &match?({:changeset_applied, _, %{}}, &1))
      )

      :ok = MemoryStore.consolidate_semantics(pid)

      assert_eventually(
        Enum.any?(TestNotifier.events(repo_id), fn
          {:consolidation_completed, %{checked: _, deleted: _, deleted_ids: _}, %{}} -> true
          _ -> false
        end)
      )
    end
  end

  describe "decay_nodes notification" do
    test "emits {:decay_completed, stats, metadata} on success", %{tmp_dir: tmp_dir} do
      repo_id = unique_repo_id()
      pid = start_store(tmp_dir, repo_id: repo_id)

      old_time = ~U[2020-01-01 00:00:00Z]
      emb = List.duplicate(0.5, 128)

      sem = %Semantic{id: "s-old", proposition: "Stale fact", confidence: 0.9, embedding: emb}
      meta = NodeMetadata.new(created_at: old_time, access_count: 0)

      changeset =
        Changeset.new()
        |> Changeset.add_node(sem)
        |> Changeset.put_metadata("s-old", meta)

      :ok = MemoryStore.apply_changeset(pid, changeset)

      assert_eventually(
        Enum.any?(TestNotifier.events(repo_id), &match?({:changeset_applied, _, %{}}, &1))
      )

      :ok = MemoryStore.decay_nodes(pid)

      assert_eventually(
        Enum.any?(TestNotifier.events(repo_id), fn
          {:decay_completed, %{checked: _, deleted: _, deleted_ids: _}, %{}} -> true
          _ -> false
        end)
      )
    end
  end
end

defmodule Mnemosyne.NotifierIngestionIntegrationTest do
  use ExUnit.Case, async: false

  import Mimic

  alias Mnemosyne.Config
  alias Mnemosyne.Errors.Framework.PipelineError
  alias Mnemosyne.Errors.Framework.StorageError
  alias Mnemosyne.Errors.Invalid.IngestionError
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Tag
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.GraphBackends.Persistence.DETS
  alias Mnemosyne.MemoryStore
  alias Mnemosyne.Pipeline.Ingestion
  alias Mnemosyne.TestNotifier
  alias Mnemosyne.Trajectory

  @moduletag :tmp_dir

  setup :set_mimic_global

  setup do
    TestNotifier.setup()
    :ok
  end

  defmodule RaisingNotifier do
    @behaviour Mnemosyne.Notifier

    @impl true
    def notify(_repo_id, _event), do: raise("boom")
  end

  defmodule BlockingNotifier do
    @behaviour Mnemosyne.Notifier

    @impl true
    def notify(_repo_id, {:trajectory_ingested, _receipt, _metadata} = event) do
      {test_pid, ref} = :persistent_term.get({__MODULE__, :test})
      send(test_pid, {:notifier_entered, event, self()})

      receive do
        {:release_notifier, ^ref} -> :ok
      end
    end

    @impl true
    def notify(_repo_id, _event), do: :ok
  end

  defp build_config do
    {:ok, config} =
      Zoi.parse(Config.t(), %{
        llm: %{model: "test-model", opts: %{}},
        embedding: %{model: "test-embed", opts: %{}}
      })

    config
  end

  defp start_store(tmp_dir, opts) do
    name = :"notifier_ingestion_#{System.unique_integer([:positive])}"
    task_sup = :"notifier_ingestion_task_#{System.unique_integer([:positive])}"

    dets_path =
      Path.join(tmp_dir, "notifier_ingestion_#{System.unique_integer([:positive])}.dets")

    start_supervised!({Task.Supervisor, name: task_sup})

    start_supervised!(
      {MemoryStore,
       Keyword.merge(
         [
           name: name,
           backend: {InMemory, persistence: {DETS, path: dets_path}},
           config: build_config(),
           llm: Mnemosyne.MockLLM,
           embedding: Mnemosyne.MockEmbedding,
           task_supervisor: task_sup,
           notifier: TestNotifier
         ],
         opts
       )},
      id: name
    )
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

  defp changeset(id),
    do: Changeset.add_node(Changeset.new(), %Semantic{id: id, proposition: id, confidence: 0.9})

  defp start_ingest(store, input), do: Task.async(fn -> MemoryStore.ingest(store, input) end)

  defp enqueue_ingest(store, input) do
    {:ok, digest} = Ingestion.prepare(input)
    tag = make_ref()
    send(store, {:"$gen_call", {self(), tag}, {:ingest, input, digest, []}})
    MemoryStore.get_graph(store)
    tag
  end

  defp ingestion_events(repo_id), do: TestNotifier.events(repo_id)

  defp ingestion_metadata(repo_id, source_id), do: %{repo_id: repo_id, source_id: source_id}

  test "commits before notifying and blocks all coalesced replies until notification completes",
       %{
         tmp_dir: tmp_dir
       } do
    test_pid = self()
    repo_id = "ingestion-notifier-repo"
    input = trajectory()
    ref = make_ref()
    :persistent_term.put({BlockingNotifier, :test}, {self(), ref})
    on_exit(fn -> :persistent_term.erase({BlockingNotifier, :test}) end)

    stub(Ingestion, :run, fn _input, _opts ->
      send(test_pid, {:extraction_started, self()})

      receive do
        {:finish_extraction, result} -> result
      end
    end)

    expect(InMemory, :commit_ingestion, fn record, final_changeset, backend_state ->
      result =
        Mimic.call_original(InMemory, :commit_ingestion, [record, final_changeset, backend_state])

      send(test_pid, :backend_committed)
      result
    end)

    store = start_store(tmp_dir, repo_id: repo_id, notifier: BlockingNotifier)
    first = start_ingest(store, input)
    assert_receive {:extraction_started, worker}
    second_tag = enqueue_ingest(store, input)

    send(worker, {:finish_extraction, {:ok, changeset("committed")}})

    assert_receive :backend_committed
    assert_receive {:notifier_entered, {:trajectory_ingested, receipt, metadata}, notifier_pid}
    assert metadata == %{repo_id: repo_id, source_id: "source-1", node_ids: ["committed"]}
    assert Task.yield(first, 0) == nil
    refute_receive {^second_tag, _}, 0

    send(notifier_pid, {:release_notifier, ref})

    assert {:ok, ^receipt} = Task.await(first)
    assert_receive {^second_tag, {:ok, ^receipt}}
  end

  test "coalesces success and suppresses persisted equal retry notifications", %{tmp_dir: tmp_dir} do
    test_pid = self()
    repo_id = "coalesced-notifier-repo"
    input = trajectory()

    stub(Ingestion, :run, fn _input, _opts ->
      send(test_pid, {:extraction_started, self()})

      receive do
        {:finish_extraction, result} -> result
      end
    end)

    store = start_store(tmp_dir, repo_id: repo_id)
    first = start_ingest(store, input)
    assert_receive {:extraction_started, worker}
    second_tag = enqueue_ingest(store, input)

    send(worker, {:finish_extraction, {:ok, changeset("coalesced")}})

    assert {:ok, receipt} = Task.await(first)
    assert_receive {^second_tag, {:ok, ^receipt}}

    assert [
             {:trajectory_ingested, ^receipt,
              %{repo_id: ^repo_id, source_id: "source-1", node_ids: ["coalesced"]}}
           ] = ingestion_events(repo_id)

    assert {:ok, ^receipt} = MemoryStore.ingest(store, input)

    assert [
             {:trajectory_ingested, ^receipt,
              %{repo_id: ^repo_id, source_id: "source-1", node_ids: ["coalesced"]}}
           ] = ingestion_events(repo_id)
  end

  test "notifies a pending source conflict without turning it into a success", %{tmp_dir: tmp_dir} do
    test_pid = self()
    repo_id = "conflict-notifier-repo"
    input = trajectory()

    stub(Ingestion, :run, fn _input, _opts ->
      send(test_pid, {:extraction_started, self()})

      receive do
        {:finish_extraction, result} -> result
      end
    end)

    store = start_store(tmp_dir, repo_id: repo_id)
    first = start_ingest(store, input)
    assert_receive {:extraction_started, worker}

    assert {:error, %IngestionError{} = error} =
             MemoryStore.ingest(store, trajectory(goal: "Different goal"))

    assert [
             {:trajectory_ingestion_failed, "source-1", ^error, metadata}
           ] = ingestion_events(repo_id)

    assert metadata == ingestion_metadata(repo_id, "source-1")

    send(worker, {:finish_extraction, {:ok, changeset("winner")}})
    assert {:ok, _receipt} = Task.await(first)

    TestNotifier.setup()

    assert {:error, %IngestionError{} = persisted_error} =
             MemoryStore.ingest(store, trajectory(goal: "Different again"))

    assert [
             {:trajectory_ingestion_failed, "source-1", ^persisted_error, persisted_metadata}
           ] = ingestion_events(repo_id)

    assert persisted_metadata == ingestion_metadata(repo_id, "source-1")
  end

  test "notifies extraction and task failures with their original errors", %{tmp_dir: tmp_dir} do
    repo_id = "extraction-notifier-repo"
    extraction_error = PipelineError.exception(reason: :extraction_failed)

    stub(Ingestion, :run, fn
      %Trajectory{source_id: "extraction"}, _opts -> {:error, extraction_error}
      %Trajectory{source_id: "crash"}, _opts -> raise "boom"
    end)

    store = start_store(tmp_dir, repo_id: repo_id)

    assert {:error, ^extraction_error} =
             MemoryStore.ingest(store, trajectory(source_id: "extraction"))

    assert {:error, %PipelineError{reason: {:task_crashed, {%RuntimeError{message: "boom"}, _}}}} =
             MemoryStore.ingest(store, trajectory(source_id: "crash"))

    events = ingestion_events(repo_id)
    assert length(events) == 2

    assert Enum.any?(events, fn
             {:trajectory_ingestion_failed, "extraction", ^extraction_error, extraction_metadata} ->
               extraction_metadata == ingestion_metadata(repo_id, "extraction")

             _ ->
               false
           end)

    assert Enum.any?(events, fn
             {:trajectory_ingestion_failed, "crash",
              %PipelineError{reason: {:task_crashed, {%RuntimeError{message: "boom"}, _}}},
              crash_metadata} ->
               crash_metadata == ingestion_metadata(repo_id, "crash")

             _ ->
               false
           end)
  end

  test "notifies backend read, merge, and commit failures with the returned error", %{
    tmp_dir: tmp_dir
  } do
    repo_id = "storage-notifier-repo"
    read_error = StorageError.exception(operation: :get_ingestion, reason: :unavailable)
    merge_error = StorageError.exception(operation: :get_nodes_by_type, reason: :unavailable)
    commit_error = StorageError.exception(operation: :commit_ingestion, reason: :disk_full)

    stub(Ingestion, :run, fn
      %Trajectory{source_id: "merge"}, _opts ->
        {:ok,
         Changeset.new()
         |> Changeset.add_node(%Semantic{id: "merge", proposition: "merge", confidence: 0.9})
         |> Changeset.add_node(%Tag{id: "merge-tag", label: "merge"})}

      input, _opts ->
        {:ok, changeset(input.source_id)}
    end)

    stub(InMemory, :get_ingestion, fn
      "read", _backend_state ->
        {:error, read_error}

      source_id, backend_state ->
        Mimic.call_original(InMemory, :get_ingestion, [source_id, backend_state])
    end)

    stub(InMemory, :get_nodes_by_type, fn
      [:tag], _backend_state ->
        {:error, merge_error}

      types, backend_state ->
        Mimic.call_original(InMemory, :get_nodes_by_type, [types, backend_state])
    end)

    stub(InMemory, :commit_ingestion, fn record, final_changeset, backend_state ->
      if record.source_id == "commit" do
        {:error, commit_error}
      else
        Mimic.call_original(InMemory, :commit_ingestion, [record, final_changeset, backend_state])
      end
    end)

    store = start_store(tmp_dir, repo_id: repo_id)

    assert {:error, ^read_error} = MemoryStore.ingest(store, trajectory(source_id: "read"))
    assert {:error, ^merge_error} = MemoryStore.ingest(store, trajectory(source_id: "merge"))
    assert {:error, ^commit_error} = MemoryStore.ingest(store, trajectory(source_id: "commit"))

    events = ingestion_events(repo_id)
    assert length(events) == 3

    for {source_id, error} <- [
          {"read", read_error},
          {"merge", merge_error},
          {"commit", commit_error}
        ] do
      assert Enum.any?(events, fn
               {:trajectory_ingestion_failed, ^source_id, ^error, metadata} ->
                 metadata == ingestion_metadata(repo_id, source_id)

               _ ->
                 false
             end)
    end
  end

  test "suppresses an outcome for a late equal compare-and-set receipt", %{tmp_dir: tmp_dir} do
    repo_id = "late-equal-notifier-repo"
    input = trajectory(source_id: "late-equal")
    calls = :counters.new(1, [:atomics])

    stub(Ingestion, :run, fn _input, _opts -> {:ok, changeset("late-equal-node")} end)

    stub(InMemory, :get_ingestion, fn source_id, backend_state ->
      :counters.add(calls, 1, 1)

      if :counters.get(calls, 1) == 2 do
        {:ok, nil, backend_state}
      else
        Mimic.call_original(InMemory, :get_ingestion, [source_id, backend_state])
      end
    end)

    store = start_store(tmp_dir, repo_id: repo_id)
    assert {:ok, receipt} = MemoryStore.ingest(store, input)

    assert [
             {:trajectory_ingested, ^receipt,
              %{repo_id: ^repo_id, source_id: "late-equal", node_ids: ["late-equal-node"]}}
           ] = ingestion_events(repo_id)

    assert {:ok, ^receipt} = MemoryStore.ingest(store, input)

    assert [
             {:trajectory_ingested, ^receipt,
              %{repo_id: ^repo_id, source_id: "late-equal", node_ids: ["late-equal-node"]}}
           ] = ingestion_events(repo_id)
  end

  test "notifies a source conflict returned by the backend compare-and-set", %{tmp_dir: tmp_dir} do
    repo_id = "cas-conflict-notifier-repo"
    calls = :counters.new(1, [:atomics])

    stub(Ingestion, :run, fn input, _opts -> {:ok, changeset("#{input.source_id}-node")} end)

    stub(InMemory, :get_ingestion, fn source_id, backend_state ->
      :counters.add(calls, 1, 1)

      if :counters.get(calls, 1) == 2 do
        {:ok, nil, backend_state}
      else
        Mimic.call_original(InMemory, :get_ingestion, [source_id, backend_state])
      end
    end)

    store = start_store(tmp_dir, repo_id: repo_id)
    input = trajectory(source_id: "cas-conflict")
    assert {:ok, _receipt} = MemoryStore.ingest(store, input)
    TestNotifier.setup()

    assert {:error, %IngestionError{} = error} =
             MemoryStore.ingest(
               store,
               trajectory(source_id: "cas-conflict", goal: "Different goal")
             )

    assert [
             {:trajectory_ingestion_failed, "cas-conflict", ^error,
              %{repo_id: ^repo_id, source_id: "cas-conflict"}}
           ] = ingestion_events(repo_id)
  end

  test "notifies a write-time merge task crash without a generic write event", %{tmp_dir: tmp_dir} do
    repo_id = "merge-crash-notifier-repo"

    changeset =
      Changeset.new()
      |> Changeset.add_node(%Semantic{
        id: "merge-crash",
        proposition: "merge crash",
        confidence: 0.9
      })
      |> Changeset.add_node(%Tag{id: "merge-crash-tag", label: "merge crash"})

    stub(Ingestion, :run, fn _input, _opts -> {:ok, changeset} end)

    stub(InMemory, :get_nodes_by_type, fn
      [:tag], _backend_state ->
        raise "merge boom"

      types, backend_state ->
        Mimic.call_original(InMemory, :get_nodes_by_type, [types, backend_state])
    end)

    store = start_store(tmp_dir, repo_id: repo_id)

    assert {:error,
            %PipelineError{reason: {:task_crashed, {%RuntimeError{message: "merge boom"}, _}}}} =
             MemoryStore.ingest(store, trajectory(source_id: "merge-crash"))

    assert [
             {:trajectory_ingestion_failed, "merge-crash",
              %PipelineError{reason: {:task_crashed, {%RuntimeError{message: "merge boom"}, _}}},
              %{repo_id: ^repo_id, source_id: "merge-crash"}}
           ] = ingestion_events(repo_id)
  end

  test "does not notify invalid input rejected before admission", %{tmp_dir: tmp_dir} do
    repo_id = "invalid-notifier-repo"
    store = start_store(tmp_dir, repo_id: repo_id)

    assert {:error, %IngestionError{reason: :invalid_goal}} =
             MemoryStore.ingest(store, trajectory(goal: " "))

    assert ingestion_events(repo_id) == []
  end

  test "isolates notifier failures from persistence, retries, and failure cleanup", %{
    tmp_dir: tmp_dir
  } do
    retries = :counters.new(1, [:atomics])

    stub(Ingestion, :run, fn
      %Trajectory{source_id: "failed"}, _opts ->
        :counters.add(retries, 1, 1)

        if :counters.get(retries, 1) == 1 do
          {:error, :extraction_failed}
        else
          {:ok, changeset("recovered")}
        end

      _input, _opts ->
        {:ok, changeset("isolated")}
    end)

    store = start_store(tmp_dir, repo_id: "raising-notifier-repo", notifier: RaisingNotifier)
    input = trajectory()

    assert {:ok, receipt} = MemoryStore.ingest(store, input)
    assert %{nodes: %{"isolated" => %Semantic{}}} = MemoryStore.get_graph(store)
    assert {:ok, ^receipt} = MemoryStore.ingest(store, input)

    assert {:error, :extraction_failed} =
             MemoryStore.ingest(store, trajectory(source_id: "failed"))

    assert {:ok, %{node_ids: ["recovered"]}} =
             MemoryStore.ingest(store, trajectory(source_id: "failed"))
  end
end

defmodule Mnemosyne.NotifierRecallIntegrationTest do
  use ExUnit.Case, async: false
  use AssertEventually, timeout: 500, interval: 10

  import Mimic

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Tag
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.GraphBackends.Persistence.DETS
  alias Mnemosyne.LLM
  alias Mnemosyne.MemoryStore
  alias Mnemosyne.TestNotifier

  @moduletag :tmp_dir

  setup :set_mimic_global

  setup do
    TestNotifier.setup()
    :ok
  end

  defp build_config do
    {:ok, config} =
      Zoi.parse(Config.t(), %{
        llm: %{model: "test-model", opts: %{}},
        embedding: %{model: "test-embed", opts: %{}}
      })

    config
  end

  defp unique_name, do: :"notifier_recall_#{System.unique_integer([:positive])}"

  defp unique_repo_id, do: "repo-#{System.unique_integer([:positive])}"

  defp start_store(tmp_dir, opts) do
    dets_path = Path.join(tmp_dir, "test_store_#{System.unique_integer([:positive])}.dets")
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
          task_supervisor: task_sup,
          notifier: TestNotifier
        ],
        opts
      )

    start_supervised!({MemoryStore, store_opts}, id: name)
  end

  describe "recall notification" do
    test "emits {:recall_executed, query, result, metadata} on success", %{tmp_dir: tmp_dir} do
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

      repo_id = unique_repo_id()
      pid = start_store(tmp_dir, repo_id: repo_id)

      node = %Semantic{id: "s1", proposition: "Elixir is functional", confidence: 0.9}
      tag = %Tag{id: "t1", label: "elixir"}

      changeset =
        Changeset.new()
        |> Changeset.add_node(node)
        |> Changeset.add_node(tag)

      :ok = MemoryStore.apply_changeset(pid, changeset)

      assert_eventually(
        Enum.any?(TestNotifier.events(repo_id), &match?({:changeset_applied, _, %{}}, &1))
      )

      context = %{
        goal: "Learn Elixir",
        recent_steps: [%{observation: "Read docs", action: "Took notes"}]
      }

      {:ok, _} =
        MemoryStore.recall(pid, "what is elixir?", context: context, source_id: "source-1")

      expected_query =
        "Goal: Learn Elixir\nRecent context:\n- Read docs -> Took notes\n\nQuery: what is elixir?"

      assert {:recall_executed, ^expected_query, {:ok, _}, metadata} =
               Enum.find(TestNotifier.events(repo_id), &match?({:recall_executed, _, _, _}, &1))

      assert metadata.source_id == "source-1"
      assert metadata.trace.source_id == "source-1"
      refute Map.has_key?(metadata, :session_id)
    end

    test "emits {:recall_failed, query, reason, metadata} on failure", %{tmp_dir: tmp_dir} do
      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        {:error, :llm_unavailable}
      end)

      stub(Mnemosyne.MockEmbedding, :embed, fn _text, _opts ->
        {:error, :embed_unavailable}
      end)

      stub(Mnemosyne.MockEmbedding, :embed_batch, fn _texts, _opts ->
        {:error, :embed_unavailable}
      end)

      repo_id = unique_repo_id()
      pid = start_store(tmp_dir, repo_id: repo_id)

      {:error, _} = MemoryStore.recall(pid, "failing query", source_id: "source-2")

      assert {:recall_failed, "failing query", _reason, metadata} =
               Enum.find(TestNotifier.events(repo_id), &match?({:recall_failed, _, _, _}, &1))

      assert metadata == %{source_id: "source-2"}
      assert :sys.get_state(pid).pending_recalls == %{}
    end
  end
end
