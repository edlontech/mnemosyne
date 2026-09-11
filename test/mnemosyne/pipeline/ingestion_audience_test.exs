defmodule Mnemosyne.Pipeline.IngestionAudienceTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Pipeline.Ingestion
  alias Mnemosyne.Trajectory

  test "audience ordering and duplicates do not change identity, and malformed audiences are rejected" do
    trajectory = %Trajectory{
      source_id: "source",
      goal: "Investigate",
      steps: [%{observation: "Issue", action: "Inspect"}],
      audience: [{"org", "security"}, {"org", "payments"}, {"org", "security"}]
    }

    reordered = %{trajectory | audience: [{"org", "payments"}, {"org", "security"}]}
    assert Ingestion.prepare(trajectory) == Ingestion.prepare(reordered)
    assert {:error, _} = Ingestion.prepare(%{trajectory | audience: []})
    assert {:error, _} = Ingestion.prepare(%{trajectory | audience: ["security"]})
  end

  test "the audience is part of a trajectory's payload identity" do
    trajectory = %Trajectory{
      source_id: "source-1",
      goal: "Investigate a failure",
      steps: [%{observation: "A failure", action: "Read logs"}]
    }

    assert {:ok, shared} = Ingestion.prepare(Map.put(trajectory, :audience, :repo))

    assert {:ok, restricted} =
             Ingestion.prepare(Map.put(trajectory, :audience, [{"org", "security"}]))

    refute shared == restricted
    refute Ingestion.prepare(trajectory) == {:ok, shared}
  end
end
