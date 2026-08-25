defmodule Mnemosyne.GraphBackends.Persistence.DETSTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Errors.Framework.StorageError
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.GraphBackends.Persistence.DETS, as: PersistenceDETS
  alias Mnemosyne.IngestionReceipt
  alias Mnemosyne.NodeMetadata

  @moduletag :tmp_dir

  defp semantic_node(id) do
    %Semantic{id: id, proposition: "fact #{id}", confidence: 0.9}
  end

  defp ingestion_record do
    %{
      source_id: "source-1",
      payload_digest: <<1, 2, 3, 4>>,
      fingerprint_version: 1,
      receipt: %IngestionReceipt{
        source_id: "source-1",
        node_ids: ["s1"],
        stored_at: ~U[2026-08-25 12:34:56.123456Z]
      }
    }
  end

  describe "init/1" do
    test "opens a DETS file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.dets")
      assert {:ok, state} = PersistenceDETS.init(path: path)
      assert is_map(state)
      :dets.close(state.ref)
    end
  end

  describe "save/2 and load/1" do
    test "round-trips nodes", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "roundtrip.dets")
      {:ok, state} = PersistenceDETS.init(path: path)

      changeset =
        Changeset.new()
        |> Changeset.add_node(semantic_node("s1"))
        |> Changeset.add_node(semantic_node("s2"))

      assert :ok = PersistenceDETS.save(changeset, state)

      {:ok, graph, _metadata, _ingestions} = PersistenceDETS.load(state)
      assert %Semantic{id: "s1"} = graph.nodes["s1"]
      assert %Semantic{id: "s2"} = graph.nodes["s2"]

      :dets.close(state.ref)
    end

    test "persists an exact linked ingestion after close and reopen", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "ingestion.dets")
      {:ok, state} = PersistenceDETS.init(path: path)
      original_record = ingestion_record()
      receipt = %{original_record.receipt | node_ids: ["s1", "s2"]}
      record = %{original_record | receipt: receipt}
      metadata_s1 = NodeMetadata.new(created_at: ~U[2026-08-25 11:00:00Z])
      metadata_s2 = NodeMetadata.new(created_at: ~U[2026-08-25 11:30:00Z])

      changeset =
        Changeset.new()
        |> Changeset.add_node(semantic_node("s1"))
        |> Changeset.add_node(semantic_node("s2"))
        |> Changeset.add_link("s1", "s2", :sibling)
        |> Changeset.put_metadata("s1", metadata_s1)
        |> Changeset.put_metadata("s2", metadata_s2)

      assert :ok = PersistenceDETS.commit_ingestion(record, changeset, state)
      assert :ok = :dets.close(state.ref)

      {:ok, reopened} = PersistenceDETS.init(path: path)

      assert [{{:ingestion, "source-1"}, ^record}] =
               :dets.lookup(reopened.ref, {:ingestion, "source-1"})

      assert {:ok, graph, persisted_metadata, ingestions} = PersistenceDETS.load(reopened)
      assert %Semantic{id: "s1"} = graph.nodes["s1"]
      assert %Semantic{id: "s2"} = graph.nodes["s2"]
      assert graph.nodes["s1"].links.sibling == MapSet.new(["s2"])
      assert graph.nodes["s2"].links.sibling == MapSet.new(["s1"])
      assert persisted_metadata == %{"s1" => metadata_s1, "s2" => metadata_s2}
      assert ingestions == %{"source-1" => record}
      assert ingestions["source-1"].payload_digest == <<1, 2, 3, 4>>
      assert ingestions["source-1"].fingerprint_version == 1

      assert ingestions["source-1"].receipt == %IngestionReceipt{
               source_id: "source-1",
               node_ids: ["s1", "s2"],
               stored_at: ~U[2026-08-25 12:34:56.123456Z]
             }

      :dets.close(reopened.ref)
    end

    test "preserves links", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "links.dets")
      {:ok, state} = PersistenceDETS.init(path: path)

      changeset =
        Changeset.new()
        |> Changeset.add_node(semantic_node("s1"))
        |> Changeset.add_node(semantic_node("s2"))
        |> Changeset.add_link("s1", "s2", :sibling)

      assert :ok = PersistenceDETS.save(changeset, state)

      {:ok, graph, _metadata, _ingestions} = PersistenceDETS.load(state)
      assert MapSet.member?(Map.get(graph.nodes["s1"].links, :sibling, MapSet.new()), "s2")
      assert MapSet.member?(Map.get(graph.nodes["s2"].links, :sibling, MapSet.new()), "s1")

      :dets.close(state.ref)
    end
  end

  describe "delete/2" do
    test "removes nodes from DETS", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "delete.dets")
      {:ok, state} = PersistenceDETS.init(path: path)

      changeset =
        Changeset.new()
        |> Changeset.add_node(semantic_node("s1"))
        |> Changeset.add_node(semantic_node("s2"))

      :ok = PersistenceDETS.save(changeset, state)
      assert :ok = PersistenceDETS.delete(["s1"], state)

      {:ok, graph, _metadata, _ingestions} = PersistenceDETS.load(state)
      assert is_nil(graph.nodes["s1"])
      assert %Semantic{id: "s2"} = graph.nodes["s2"]

      :dets.close(state.ref)
    end

    test "strips back-references from surviving nodes after reload", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "delete_backrefs.dets")
      {:ok, state} = PersistenceDETS.init(path: path)

      changeset =
        Changeset.new()
        |> Changeset.add_node(semantic_node("s1"))
        |> Changeset.add_node(semantic_node("s2"))
        |> Changeset.add_node(semantic_node("s3"))
        |> Changeset.add_link("s1", "s2", :sibling)
        |> Changeset.add_link("s1", "s3", :sibling)
        |> Changeset.add_link("s2", "s3", :sibling)

      :ok = PersistenceDETS.save(changeset, state)
      :ok = PersistenceDETS.delete(["s1"], state)

      {:ok, graph, _metadata, _ingestions} = PersistenceDETS.load(state)
      s2_siblings = Map.get(graph.nodes["s2"].links, :sibling, MapSet.new())
      s3_siblings = Map.get(graph.nodes["s3"].links, :sibling, MapSet.new())

      refute MapSet.member?(s2_siblings, "s1")
      refute MapSet.member?(s3_siblings, "s1")
      assert MapSet.member?(s2_siblings, "s3")
      assert MapSet.member?(s3_siblings, "s2")

      :dets.close(state.ref)
    end

    test "strips back-references across multiple link types and batched deletes",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "delete_batch.dets")
      {:ok, state} = PersistenceDETS.init(path: path)

      changeset =
        Changeset.new()
        |> Changeset.add_node(semantic_node("dead1"))
        |> Changeset.add_node(semantic_node("dead2"))
        |> Changeset.add_node(semantic_node("survivor"))
        |> Changeset.add_link("survivor", "dead1", :sibling)
        |> Changeset.add_link("survivor", "dead2", :membership)
        |> Changeset.add_link("dead1", "dead2", :provenance)

      :ok = PersistenceDETS.save(changeset, state)
      :ok = PersistenceDETS.delete(["dead1", "dead2"], state)

      {:ok, graph, _metadata, _ingestions} = PersistenceDETS.load(state)
      assert is_nil(graph.nodes["dead1"])
      assert is_nil(graph.nodes["dead2"])

      survivor_links = graph.nodes["survivor"].links
      assert MapSet.size(Map.get(survivor_links, :sibling, MapSet.new())) == 0
      assert MapSet.size(Map.get(survivor_links, :membership, MapSet.new())) == 0

      :dets.close(state.ref)
    end
  end

  describe "save_metadata/2 and load/1" do
    test "round-trips metadata records", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "meta_roundtrip.dets")
      {:ok, state} = PersistenceDETS.init(path: path)

      meta1 = NodeMetadata.new(created_at: ~U[2025-01-01 00:00:00Z], access_count: 3)
      meta2 = NodeMetadata.new(created_at: ~U[2025-06-01 00:00:00Z])

      :ok = PersistenceDETS.save_metadata(%{"s1" => meta1, "s2" => meta2}, state)

      {:ok, _graph, metadata, _ingestions} = PersistenceDETS.load(state)
      assert %NodeMetadata{access_count: 3} = metadata["s1"]
      assert %NodeMetadata{} = metadata["s2"]

      :dets.close(state.ref)
    end

    test "load distinguishes node records from metadata records", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "mixed.dets")
      {:ok, state} = PersistenceDETS.init(path: path)

      changeset =
        Changeset.add_node(Changeset.new(), semantic_node("s1"))

      :ok = PersistenceDETS.save(changeset, state)

      meta = NodeMetadata.new(created_at: ~U[2025-01-01 00:00:00Z])
      :ok = PersistenceDETS.save_metadata(%{"s1" => meta}, state)

      {:ok, graph, metadata, _ingestions} = PersistenceDETS.load(state)
      assert %Semantic{id: "s1"} = graph.nodes["s1"]
      assert %NodeMetadata{} = metadata["s1"]

      :dets.close(state.ref)
    end
  end

  describe "delete_metadata/2" do
    test "removes metadata entries", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "meta_delete.dets")
      {:ok, state} = PersistenceDETS.init(path: path)

      meta = NodeMetadata.new(created_at: ~U[2025-01-01 00:00:00Z])
      :ok = PersistenceDETS.save_metadata(%{"s1" => meta, "s2" => meta}, state)

      :ok = PersistenceDETS.delete_metadata(["s1"], state)

      {:ok, _graph, metadata, _ingestions} = PersistenceDETS.load(state)
      refute Map.has_key?(metadata, "s1")
      assert Map.has_key?(metadata, "s2")

      :dets.close(state.ref)
    end
  end

  describe "InMemory integration" do
    alias Mnemosyne.GraphBackends.InMemory

    test "loads the exact ingestion record after close and re-init", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "ingestion_integration.dets")
      persistence = {PersistenceDETS, [path: path]}
      record = ingestion_record()

      {:ok, state} = InMemory.init(persistence: persistence)
      changeset = Changeset.add_node(Changeset.new(), semantic_node("s1"))
      {:ok, receipt, state} = InMemory.commit_ingestion(record, changeset, state)

      assert receipt == record.receipt
      assert :ok = :dets.close(state.persistence |> elem(1) |> Map.fetch!(:ref))

      {:ok, reopened} = InMemory.init(persistence: persistence)
      assert {:ok, ^record, ^reopened} = InMemory.get_ingestion("source-1", reopened)
      assert {:ok, %Semantic{id: "s1"}, ^reopened} = InMemory.get_node("s1", reopened)

      {:ok, deleted} = InMemory.delete_nodes(["s1"], reopened)
      assert :ok = :dets.close(deleted.persistence |> elem(1) |> Map.fetch!(:ref))

      {:ok, reopened_after_delete} = InMemory.init(persistence: persistence)

      assert {:ok, ^record, ^reopened_after_delete} =
               InMemory.get_ingestion("source-1", reopened_after_delete)

      assert {:ok, nil, ^reopened_after_delete} =
               InMemory.get_node("s1", reopened_after_delete)

      :dets.close(reopened_after_delete.persistence |> elem(1) |> Map.fetch!(:ref))
    end

    test "returns a storage error without mutating caller state when DETS is closed", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "closed_ingestion.dets")
      persistence = {PersistenceDETS, [path: path]}
      original_record = ingestion_record()
      original_metadata = NodeMetadata.new(created_at: ~U[2026-08-25 11:00:00Z])

      {:ok, state} = InMemory.init(persistence: persistence)

      original_changeset =
        Changeset.new()
        |> Changeset.add_node(semantic_node("s1"))
        |> Changeset.put_metadata("s1", original_metadata)

      {:ok, _receipt, state} =
        InMemory.commit_ingestion(original_record, original_changeset, state)

      original_graph = state.graph
      original_metadata_map = state.metadata
      original_ingestions = state.ingestions
      assert :ok = :dets.close(state.persistence |> elem(1) |> Map.fetch!(:ref))

      receipt = %{original_record.receipt | source_id: "source-2", node_ids: ["s2"]}

      record = %{
        original_record
        | source_id: "source-2",
          payload_digest: <<5, 6, 7, 8>>,
          receipt: receipt
      }

      changeset =
        Changeset.new()
        |> Changeset.add_node(semantic_node("s2"))
        |> Changeset.put_metadata("s2", NodeMetadata.new())

      assert {:error, %StorageError{operation: :commit_ingestion, reason: %ArgumentError{}}} =
               InMemory.commit_ingestion(record, changeset, state)

      assert state.graph == original_graph
      assert state.metadata == original_metadata_map
      assert state.ingestions == original_ingestions
    end

    test "survives re-init with DETS persistence", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "integration.dets")
      persistence = {PersistenceDETS, [path: path]}

      {:ok, state} = InMemory.init(persistence: persistence)

      changeset =
        Changeset.new()
        |> Changeset.add_node(semantic_node("s1"))
        |> Changeset.add_node(semantic_node("s2"))
        |> Changeset.add_link("s1", "s2", :sibling)

      {:ok, _state} = InMemory.apply_changeset(changeset, state)

      {:ok, state2} = InMemory.init(persistence: persistence)
      assert {:ok, %Semantic{id: "s1"}, _} = InMemory.get_node("s1", state2)
      assert {:ok, %Semantic{id: "s2"}, _} = InMemory.get_node("s2", state2)

      %Semantic{links: links} = state2.graph.nodes["s1"]
      assert MapSet.member?(Map.get(links, :sibling, MapSet.new()), "s2")

      :dets.close(state2.persistence |> elem(1) |> Map.get(:ref))
    end
  end
end
