defmodule Mnemosyne.GraphBackends.AudiencePersistenceTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.IngestionReceipt
  alias Mnemosyne.NodeMetadata

  test "ingestion commits cannot reclassify an existing node" do
    metadata = NodeMetadata.new(audience: [{"org", "security"}])
    state = %InMemory{metadata: %{"node" => metadata}}

    changeset =
      Changeset.put_metadata(Changeset.new(), "node", %{
        metadata
        | audience: :repo
      })

    record = %{
      source_id: "new",
      payload_digest: <<1>>,
      fingerprint_version: 1,
      receipt: %IngestionReceipt{
        source_id: "new",
        node_ids: [],
        stored_at: DateTime.utc_now()
      }
    }

    assert {:error, _} = InMemory.commit_ingestion(record, changeset, state)
  end

  test "metadata updates cannot replace or remove an assigned audience" do
    audience = [{"org", "security"}]
    metadata = NodeMetadata.new(audience: audience)
    state = %InMemory{metadata: %{"node" => metadata}}

    assert {:error, _} =
             InMemory.update_metadata(%{"node" => %{metadata | audience: :repo}}, state)

    assert {:error, _} = InMemory.update_metadata(%{"node" => %{metadata | audience: nil}}, state)

    assert {:ok, updated} =
             InMemory.update_metadata(%{"node" => NodeMetadata.record_access(metadata)}, state)

    assert updated.metadata["node"].audience == audience
    assert updated.metadata["node"].access_count == 1
  end
end
