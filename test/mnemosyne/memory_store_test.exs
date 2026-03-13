defmodule Mnemosyne.MemoryStoreTest do
  use ExUnit.Case, async: false

  import Mimic

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.Graph
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Tag
  alias Mnemosyne.LLM
  alias Mnemosyne.MemoryStore
  alias Mnemosyne.Pipeline.Reasoning.ReasonedMemory

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
    persistence = {Mnemosyne.GraphBackends.Persistence.DETS, path: dets_path}
    task_sup = :"task_sup_#{System.unique_integer([:positive])}"
    name = Keyword.get_lazy(opts, :name, &unique_name/0)
    start_supervised!({Task.Supervisor, name: task_sup})

    store_opts =
      Keyword.merge(
        [
          name: name,
          backend: {Mnemosyne.GraphBackends.InMemory, persistence: persistence},
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
    {:ok, state} = Mnemosyne.GraphBackends.Persistence.DETS.init(path: dets_path)
    node = %Semantic{id: "pre-1", proposition: "Preloaded fact", confidence: 0.8}
    changeset = Changeset.add_node(Changeset.new(), node)
    :ok = Mnemosyne.GraphBackends.Persistence.DETS.save(changeset, state)
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

      graph = MemoryStore.get_graph(pid)
      assert %Semantic{proposition: "Test fact"} = Graph.get_node(graph, "s1")
    end

    test "persists changes to DETS so they survive reload", %{tmp_dir: tmp_dir} do
      name1 = unique_name()
      pid = start_store(tmp_dir, name: name1)

      node = make_semantic("s2", "Persistent fact")
      changeset = Changeset.add_node(Changeset.new(), node)
      :ok = MemoryStore.apply_changeset(pid, changeset)

      stop_supervised!(name1)

      name2 = unique_name()
      pid2 = start_store(tmp_dir, name: name2)
      graph = MemoryStore.get_graph(pid2)
      assert %Semantic{proposition: "Persistent fact"} = Graph.get_node(graph, "s2")
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

      assert :ok = MemoryStore.delete_nodes(pid, ["del-1"])

      graph = MemoryStore.get_graph(pid)
      assert Graph.get_node(graph, "del-1") == nil
    end
  end

  describe "recall/3" do
    test "runs retrieval and reasoning pipeline, returns ReasonedMemory", %{tmp_dir: tmp_dir} do
      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        {:ok, %LLM.Response{content: "semantic", model: "test", usage: %{}}}
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

      assert {:ok, %ReasonedMemory{}} = MemoryStore.recall(pid, "what is elixir?")
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

  describe "recall_in_context/4" do
    test "falls back to raw query when Session module is unavailable", %{tmp_dir: tmp_dir} do
      stub(Mnemosyne.MockLLM, :chat, fn _messages, _opts ->
        {:ok, %LLM.Response{content: "semantic", model: "test", usage: %{}}}
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

      assert {:ok, %ReasonedMemory{}} =
               MemoryStore.recall_in_context(pid, "nonexistent-session", "what is elixir?")
    end
  end
end
