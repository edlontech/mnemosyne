defmodule Mnemosyne.Pipeline.ForgetTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Errors.Framework.NotFoundError
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Tag
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.IngestionReceipt
  alias Mnemosyne.NodeMetadata
  alias Mnemosyne.Pipeline.Forget

  defp semantic(id),
    do: %Semantic{id: id, proposition: id, confidence: 1.0, embedding: [1.0, 0.0]}

  defp tag(id), do: %Tag{id: id, label: id, embedding: [0.0, 1.0]}

  defp commit(backend, source_id, changeset) do
    record = %{
      source_id: source_id,
      payload_digest: :crypto.hash(:sha256, source_id),
      fingerprint_version: 1,
      receipt: %IngestionReceipt{
        source_id: source_id,
        node_ids: Enum.map(changeset.additions, & &1.id),
        stored_at: DateTime.utc_now()
      }
    }

    {:ok, :inserted, _receipt, backend} = InMemory.commit_ingestion(record, changeset, backend)
    backend
  end

  test "deletes the ingestion's nodes, metadata, orphaned tags, and the record" do
    changeset =
      Changeset.new()
      |> Changeset.add_node(semantic("sem_a"))
      |> Changeset.add_node(tag("tag_a"))
      |> Changeset.add_link("sem_a", "tag_a", :membership)
      |> Changeset.put_metadata("sem_a", NodeMetadata.new())
      |> Changeset.put_metadata("tag_a", NodeMetadata.new())

    {:ok, backend} = InMemory.init([])
    backend = commit(backend, "source-a", changeset)

    assert {:ok, %{source_id: "source-a", deleted_ids: deleted}, {InMemory, backend}} =
             Forget.forget("source-a", backend: {InMemory, backend})

    assert Enum.sort(deleted) == ["sem_a", "tag_a"]
    assert {:ok, nil, _} = InMemory.get_node("sem_a", backend)
    assert {:ok, nil, _} = InMemory.get_node("tag_a", backend)
    assert {:ok, %{}, _} = InMemory.get_metadata(["sem_a", "tag_a"], backend)
    assert {:ok, nil, _} = InMemory.get_ingestion("source-a", backend)
  end

  test "keeps a tag this ingestion created once another ingestion links to it" do
    changeset_a =
      Changeset.new()
      |> Changeset.add_node(semantic("sem_a"))
      |> Changeset.add_node(tag("shared_tag"))
      |> Changeset.add_link("sem_a", "shared_tag", :membership)

    changeset_b =
      Changeset.new()
      |> Changeset.add_node(semantic("sem_b"))
      |> Changeset.add_link("sem_b", "shared_tag", :membership)

    {:ok, backend} = InMemory.init([])
    backend = backend |> commit("source-a", changeset_a) |> commit("source-b", changeset_b)

    assert {:ok, %{deleted_ids: ["sem_a"]}, {InMemory, backend}} =
             Forget.forget("source-a", backend: {InMemory, backend})

    assert {:ok, %Tag{id: "shared_tag"}, _} = InMemory.get_node("shared_tag", backend)
    assert {:ok, %Semantic{id: "sem_b"}, _} = InMemory.get_node("sem_b", backend)
    assert {:ok, %{source_id: "source-b"}, _} = InMemory.get_ingestion("source-b", backend)
  end

  test "skips receipt node ids that no longer exist" do
    changeset =
      Changeset.new()
      |> Changeset.add_node(semantic("sem_a"))
      |> Changeset.add_node(semantic("sem_gone"))

    {:ok, backend} = InMemory.init([])
    backend = commit(backend, "source-a", changeset)
    {:ok, backend} = InMemory.delete_nodes(["sem_gone"], backend)

    assert {:ok, %{deleted_ids: ["sem_a"]}, {InMemory, _}} =
             Forget.forget("source-a", backend: {InMemory, backend})
  end

  test "returns not found for an unknown source" do
    {:ok, backend} = InMemory.init([])

    assert {:error, %NotFoundError{resource: :ingestion, id: "missing"}} =
             Forget.forget("missing", backend: {InMemory, backend})
  end
end
