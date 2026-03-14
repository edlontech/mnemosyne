defmodule Mnemosyne.NotifierTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Notifier

  defmodule RaisingNotifier do
    @behaviour Notifier

    @impl true
    def notify(_repo_id, _event), do: raise("boom")
  end

  defmodule TrackingNotifier do
    @behaviour Notifier

    @impl true
    def notify(repo_id, event) do
      send(self(), {:notified, repo_id, event})
      :ok
    end
  end

  describe "Noop" do
    test "returns :ok for changeset_applied" do
      assert :ok = Notifier.Noop.notify("repo_1", {:changeset_applied, %{}})
    end

    test "returns :ok for nodes_deleted" do
      assert :ok = Notifier.Noop.notify("repo_1", {:nodes_deleted, ["id_1", "id_2"]})
    end

    test "returns :ok for decay_completed" do
      event = {:decay_completed, %{checked: 10, deleted: 2, deleted_ids: ["a", "b"]}}
      assert :ok = Notifier.Noop.notify("repo_1", event)
    end

    test "returns :ok for consolidation_completed" do
      event = {:consolidation_completed, %{checked: 5, deleted: 1, deleted_ids: ["c"]}}
      assert :ok = Notifier.Noop.notify("repo_1", event)
    end

    test "returns :ok for session_transition" do
      assert :ok = Notifier.Noop.notify("repo_1", {:session_transition, "s1", :open, :closed})
    end

    test "returns :ok for recall_executed" do
      assert :ok = Notifier.Noop.notify("repo_1", {:recall_executed, "query", []})
    end
  end

  describe "safe_notify/3" do
    test "returns :ok when notifier raises" do
      assert :ok = Notifier.safe_notify(RaisingNotifier, "repo_1", {:nodes_deleted, ["x"]})
    end

    test "calls notifier successfully when it does not raise" do
      assert :ok = Notifier.safe_notify(TrackingNotifier, "repo_1", {:nodes_deleted, ["x"]})
      assert_received {:notified, "repo_1", {:nodes_deleted, ["x"]}}
    end
  end
end
