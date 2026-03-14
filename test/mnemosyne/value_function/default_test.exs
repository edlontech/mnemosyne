defmodule Mnemosyne.ValueFunction.DefaultTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.NodeMetadata
  alias Mnemosyne.ValueFunction.Default

  describe "score/4 with nil metadata" do
    test "returns raw relevance" do
      assert Default.score(0.85, %{}, nil, %{}) == 0.85
      assert Default.score(0.0, %{}, nil, %{}) == 0.0
      assert Default.score(1.0, %{}, nil, %{}) == 1.0
    end
  end

  describe "score/4 with metadata" do
    test "recently accessed scores higher than stale" do
      recent_meta =
        NodeMetadata.new(
          created_at: ~U[2025-01-01 00:00:00Z],
          last_accessed_at: DateTime.utc_now(),
          access_count: 1
        )

      stale_meta =
        NodeMetadata.new(
          created_at: ~U[2020-01-01 00:00:00Z],
          last_accessed_at: ~U[2020-01-01 00:00:00Z],
          access_count: 1
        )

      recent_score = Default.score(0.8, %{}, recent_meta, %{})
      stale_score = Default.score(0.8, %{}, stale_meta, %{})

      assert recent_score > stale_score
    end

    test "frequently accessed scores higher" do
      frequent_meta =
        NodeMetadata.new(
          created_at: ~U[2025-06-01 00:00:00Z],
          access_count: 50,
          last_accessed_at: ~U[2025-06-01 00:00:00Z]
        )

      rare_meta =
        NodeMetadata.new(
          created_at: ~U[2025-06-01 00:00:00Z],
          access_count: 1,
          last_accessed_at: ~U[2025-06-01 00:00:00Z]
        )

      frequent_score = Default.score(0.8, %{}, frequent_meta, %{})
      rare_score = Default.score(0.8, %{}, rare_meta, %{})

      assert frequent_score > rare_score
    end

    test "positive reward boosts above neutral" do
      rewarded_meta =
        NodeMetadata.new(
          cumulative_reward: 5.0,
          reward_count: 1,
          access_count: 1,
          last_accessed_at: DateTime.utc_now()
        )

      neutral_meta =
        NodeMetadata.new(
          cumulative_reward: 0.0,
          reward_count: 1,
          access_count: 1,
          last_accessed_at: DateTime.utc_now()
        )

      rewarded_score = Default.score(0.8, %{}, rewarded_meta, %{})
      neutral_score = Default.score(0.8, %{}, neutral_meta, %{})

      assert rewarded_score > neutral_score
    end

    test "negative reward penalizes below neutral" do
      penalized_meta =
        NodeMetadata.new(
          cumulative_reward: -5.0,
          reward_count: 1,
          access_count: 1,
          last_accessed_at: DateTime.utc_now()
        )

      neutral_meta =
        NodeMetadata.new(
          cumulative_reward: 0.0,
          reward_count: 1,
          access_count: 1,
          last_accessed_at: DateTime.utc_now()
        )

      penalized_score = Default.score(0.8, %{}, penalized_meta, %{})
      neutral_score = Default.score(0.8, %{}, neutral_meta, %{})

      assert penalized_score < neutral_score
    end

    test "zero relevance stays zero regardless of metadata" do
      meta =
        NodeMetadata.new(
          cumulative_reward: 10.0,
          reward_count: 1,
          access_count: 100,
          last_accessed_at: DateTime.utc_now()
        )

      assert Default.score(0.0, %{}, meta, %{}) == 0.0
    end

    test "no rewards gives reward_factor of 1.0" do
      meta_no_rewards =
        NodeMetadata.new(
          access_count: 5,
          last_accessed_at: DateTime.utc_now()
        )

      meta_neutral_reward =
        NodeMetadata.new(
          cumulative_reward: 0.0,
          reward_count: 1,
          access_count: 5,
          last_accessed_at: DateTime.utc_now()
        )

      no_reward_score = Default.score(0.8, %{}, meta_no_rewards, %{})
      neutral_score = Default.score(0.8, %{}, meta_neutral_reward, %{})

      assert no_reward_score > neutral_score
    end
  end
end
