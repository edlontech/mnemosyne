defmodule Mnemosyne.RepoLifecycleTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Errors.Framework.NotFoundError
  alias Mnemosyne.Errors.Framework.RepoError
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.Supervisor, as: MneSupervisor

  @moduletag :tmp_dir

  defp build_config do
    {:ok, config} =
      Zoi.parse(Mnemosyne.Config.t(), %{
        llm: %{model: "test-model", opts: %{}},
        embedding: %{model: "test-embed", opts: %{}}
      })

    config
  end

  defp start_sup(_tmp_dir) do
    name = :"sup_#{System.unique_integer([:positive])}"

    opts = [
      name: name,
      config: build_config(),
      llm: Mnemosyne.MockLLM,
      embedding: Mnemosyne.MockEmbedding
    ]

    start_supervised!({MneSupervisor, opts})
    name
  end

  describe "open_repo/2" do
    test "starts a repo and returns {:ok, pid}", %{tmp_dir: tmp_dir} do
      sup = start_sup(tmp_dir)

      assert {:ok, pid} =
               Mnemosyne.open_repo("project-a",
                 backend: {InMemory, []},
                 supervisor: sup
               )

      assert is_pid(pid)
      assert :sys.get_state(pid).telemetry_labels == %{}
    end

    test "retains valid telemetry labels for the open repository", %{tmp_dir: tmp_dir} do
      sup = start_sup(tmp_dir)
      labels = %{"team" => "search", environment: :test, shard: 2, billable: true}

      assert {:ok, pid} =
               Mnemosyne.open_repo("labelled",
                 backend: {InMemory, []},
                 supervisor: sup,
                 telemetry_labels: labels
               )

      assert :sys.get_state(pid).telemetry_labels == labels
    end

    test "rejects invalid telemetry labels without starting a repository", %{tmp_dir: tmp_dir} do
      sup = start_sup(tmp_dir)

      invalid_labels = [
        [],
        Date.utc_today(),
        %{1 => "value"},
        %{nested: %{key: "value"}},
        %{nested: ["value"]}
      ]

      for labels <- invalid_labels do
        assert {:error, %RepoError{repo_id: "invalid-labels", reason: :invalid_telemetry_labels}} =
                 Mnemosyne.open_repo("invalid-labels",
                   backend: {InMemory, []},
                   supervisor: sup,
                   telemetry_labels: labels
                 )

        assert Mnemosyne.list_repos(supervisor: sup) == []
      end
    end

    test "returns RepoError for duplicate repo ID", %{tmp_dir: tmp_dir} do
      sup = start_sup(tmp_dir)

      {:ok, _} = Mnemosyne.open_repo("dup", backend: {InMemory, []}, supervisor: sup)

      assert {:error, %RepoError{repo_id: "dup", reason: :already_open}} =
               Mnemosyne.open_repo("dup", backend: {InMemory, []}, supervisor: sup)
    end

    test "opens multiple repos with isolated graphs", %{tmp_dir: tmp_dir} do
      sup = start_sup(tmp_dir)

      {:ok, _} = Mnemosyne.open_repo("repo-1", backend: {InMemory, []}, supervisor: sup)
      {:ok, _} = Mnemosyne.open_repo("repo-2", backend: {InMemory, []}, supervisor: sup)

      assert length(Mnemosyne.list_repos(supervisor: sup)) == 2
    end
  end

  describe "close_repo/1" do
    test "terminates the repo process", %{tmp_dir: tmp_dir} do
      sup = start_sup(tmp_dir)

      {:ok, pid} = Mnemosyne.open_repo("to-close", backend: {InMemory, []}, supervisor: sup)
      assert Process.alive?(pid)

      assert :ok = Mnemosyne.close_repo("to-close", supervisor: sup)
      refute Process.alive?(pid)
    end

    test "returns NotFoundError for unknown repo", %{tmp_dir: tmp_dir} do
      sup = start_sup(tmp_dir)

      assert {:error, %NotFoundError{resource: :repo, id: "ghost"}} =
               Mnemosyne.close_repo("ghost", supervisor: sup)
    end
  end

  describe "list_repos/0" do
    test "returns empty list when no repos open", %{tmp_dir: tmp_dir} do
      sup = start_sup(tmp_dir)
      assert Mnemosyne.list_repos(supervisor: sup) == []
    end

    test "returns all open repo IDs", %{tmp_dir: tmp_dir} do
      sup = start_sup(tmp_dir)

      {:ok, _} = Mnemosyne.open_repo("a", backend: {InMemory, []}, supervisor: sup)
      {:ok, _} = Mnemosyne.open_repo("b", backend: {InMemory, []}, supervisor: sup)

      repos = Mnemosyne.list_repos(supervisor: sup)
      assert Enum.sort(repos) == ["a", "b"]
    end
  end
end
