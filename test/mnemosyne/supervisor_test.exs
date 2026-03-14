defmodule Mnemosyne.SupervisorTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Supervisor, as: MneSupervisor

  defp build_config do
    {:ok, config} =
      Zoi.parse(Mnemosyne.Config.t(), %{
        llm: %{model: "test-model", opts: %{}},
        embedding: %{model: "test-embed", opts: %{}}
      })

    config
  end

  defp unique_sup_name, do: :"sup_#{System.unique_integer([:positive])}"

  describe "init/1" do
    test "starts all child processes" do
      name = unique_sup_name()

      opts = [
        name: name,
        config: build_config(),
        llm: Mnemosyne.MockLLM,
        embedding: Mnemosyne.MockEmbedding
      ]

      start_supervised!({MneSupervisor, opts})

      assert Process.whereis(MneSupervisor.registry_name(name))
      assert Process.whereis(MneSupervisor.repo_registry_name(name))
      assert Process.whereis(MneSupervisor.task_supervisor_name(name))
      assert Process.whereis(MneSupervisor.repo_supervisor_name(name))
      assert Process.whereis(MneSupervisor.session_supervisor_name(name))
    end

    test "stores shared defaults in persistent_term" do
      name = unique_sup_name()
      config = build_config()

      opts = [
        name: name,
        config: config,
        llm: Mnemosyne.MockLLM,
        embedding: Mnemosyne.MockEmbedding
      ]

      start_supervised!({MneSupervisor, opts})

      defaults = MneSupervisor.get_defaults(name)
      assert defaults.config == config
      assert defaults.llm == Mnemosyne.MockLLM
      assert defaults.embedding == Mnemosyne.MockEmbedding
    end
  end

  describe "name derivation" do
    test "derives child names from supervisor name" do
      name = MyApp.Mnemosyne
      assert MneSupervisor.registry_name(name) == MyApp.Mnemosyne.Registry
      assert MneSupervisor.repo_registry_name(name) == MyApp.Mnemosyne.RepoRegistry
      assert MneSupervisor.repo_supervisor_name(name) == MyApp.Mnemosyne.RepoSupervisor
      assert MneSupervisor.task_supervisor_name(name) == MyApp.Mnemosyne.TaskSupervisor
      assert MneSupervisor.session_supervisor_name(name) == MyApp.Mnemosyne.SessionSupervisor
    end
  end
end
