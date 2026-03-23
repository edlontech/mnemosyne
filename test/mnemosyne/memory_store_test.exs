defmodule Mnemosyne.MemoryStoreTest do
  use ExUnit.Case, async: false
  use AssertEventually, timeout: 500, interval: 10

  import Mimic

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.Graph
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Tag
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.GraphBackends.Persistence.DETS
  alias Mnemosyne.LLM
  alias Mnemosyne.MemoryStore
  alias Mnemosyne.NodeMetadata
  alias Mnemosyne.Pipeline.Reasoning.ReasonedMemory
  alias Mnemosyne.Pipeline.RecallResult

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

      assert {:error, _reason} = MemoryStore.recall(pid, "crash query")
    end
  end

  describe "consolidate_semantics/2" do
    test "consolidates near-duplicate semantic nodes", %{tmp_dir: tmp_dir} do
      pid = start_store(tmp_dir)

      emb = List.duplicate(0.5, 128)
      emb_similar = List.duplicate(0.5, 127) ++ [0.50001]

      tag = %Tag{id: "t1", label: "elixir", links: MapSet.new(["s1", "s2"])}

      sem1 = %Semantic{
        id: "s1",
        proposition: "Elixir is great",
        confidence: 0.9,
        embedding: emb,
        links: MapSet.new(["t1"])
      }

      sem2 = %Semantic{
        id: "s2",
        proposition: "Elixir is awesome",
        confidence: 0.9,
        embedding: emb_similar,
        links: MapSet.new(["t1"])
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
        |> Changeset.add_link("tag-1", "sem-1")

      :ok = MemoryStore.apply_changeset(pid, cs1)
      assert_eventually(Graph.get_node(MemoryStore.get_graph(pid), "sem-1") != nil)

      sem2 = make_semantic("sem-2", "MySQL supports replication")
      tag2 = %Tag{id: "tag-2", label: "Database"}

      cs2 =
        Changeset.new()
        |> Changeset.add_node(sem2)
        |> Changeset.add_node(tag2)
        |> Changeset.add_link("tag-2", "sem-2")

      :ok = MemoryStore.apply_changeset(pid, cs2)
      assert_eventually(Graph.get_node(MemoryStore.get_graph(pid), "sem-2") != nil)

      graph = MemoryStore.get_graph(pid)
      tags = Graph.nodes_by_type(graph, :tag)
      assert [%Tag{label: "database"}] = tags

      tag = hd(tags)
      assert MapSet.member?(tag.links, "sem-1")
      assert MapSet.member?(tag.links, "sem-2")
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
        |> Changeset.add_link("t1", "s1")
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
