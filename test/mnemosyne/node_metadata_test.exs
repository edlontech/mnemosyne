defmodule Mnemosyne.NodeMetadataTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.NodeMetadata

  describe "new/1" do
    test "creates with default values" do
      meta = NodeMetadata.new()

      assert meta.access_count == 0
      assert meta.last_accessed_at == nil
      assert %DateTime{} = meta.created_at
      assert meta.cumulative_reward == 0.0
      assert meta.reward_count == 0
    end

    test "creates with initial reward values" do
      meta = NodeMetadata.new(cumulative_reward: 5.0, reward_count: 2)

      assert meta.cumulative_reward == 5.0
      assert meta.reward_count == 2
    end

    test "accepts custom created_at" do
      custom_time = ~U[2025-01-01 00:00:00Z]
      meta = NodeMetadata.new(created_at: custom_time)

      assert meta.created_at == custom_time
    end
  end

  describe "record_access/1" do
    test "bumps access_count and sets last_accessed_at" do
      meta = NodeMetadata.new()
      assert meta.access_count == 0
      assert meta.last_accessed_at == nil

      updated = NodeMetadata.record_access(meta)

      assert updated.access_count == 1
      assert %DateTime{} = updated.last_accessed_at
    end

    test "increments on repeated access" do
      meta =
        NodeMetadata.new()
        |> NodeMetadata.record_access()
        |> NodeMetadata.record_access()
        |> NodeMetadata.record_access()

      assert meta.access_count == 3
    end
  end

  describe "update_reward/2" do
    test "accumulates reward and increments count" do
      meta =
        NodeMetadata.new()
        |> NodeMetadata.update_reward(1.5)
        |> NodeMetadata.update_reward(2.5)

      assert meta.cumulative_reward == 4.0
      assert meta.reward_count == 2
    end
  end

  describe "avg_reward/1" do
    test "returns 0.0 when no rewards recorded" do
      meta = NodeMetadata.new()
      assert NodeMetadata.avg_reward(meta) == 0.0
    end

    test "computes average of recorded rewards" do
      meta =
        NodeMetadata.new()
        |> NodeMetadata.update_reward(3.0)
        |> NodeMetadata.update_reward(1.0)

      assert NodeMetadata.avg_reward(meta) == 2.0
    end
  end
end
