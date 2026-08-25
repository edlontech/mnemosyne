defmodule Mnemosyne.SupervisorTest do
  use ExUnit.Case, async: true
  use AssertEventually, timeout: 500, interval: 10

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

  defp start_supervisor(opts \\ []) do
    name = Keyword.get_lazy(opts, :name, &unique_sup_name/0)

    supervisor_opts =
      Keyword.merge(
        [
          name: name,
          config: build_config(),
          llm: Mnemosyne.MockLLM,
          embedding: Mnemosyne.MockEmbedding
        ],
        opts
      )

    start_supervised!({MneSupervisor, supervisor_opts})
    name
  end

  describe "init/1" do
    test "starts only the repo registry, task supervisor, and repo supervisor" do
      name = start_supervisor()

      assert Process.whereis(MneSupervisor.repo_registry_name(name))
      assert Process.whereis(MneSupervisor.task_supervisor_name(name))
      assert Process.whereis(MneSupervisor.repo_supervisor_name(name))

      children = Supervisor.which_children(name)
      assert length(children) == 3

      assert MapSet.new(Enum.map(children, &elem(&1, 0))) ==
               MapSet.new([
                 MneSupervisor.repo_registry_name(name),
                 MneSupervisor.task_supervisor_name(name),
                 MneSupervisor.repo_supervisor_name(name)
               ])

      test_pid = self()

      assert {:ok, _pid} =
               Task.Supervisor.start_child(MneSupervisor.task_supervisor_name(name), fn ->
                 send(test_pid, :supervised_task_ran)
               end)

      assert_receive :supervised_task_ran
    end

    test "restarts downstream children with rest_for_one" do
      name = start_supervisor()
      registry_name = MneSupervisor.repo_registry_name(name)
      task_name = MneSupervisor.task_supervisor_name(name)
      repo_name = MneSupervisor.repo_supervisor_name(name)
      registry_pid = Process.whereis(registry_name)
      task_pid = Process.whereis(task_name)
      repo_pid = Process.whereis(repo_name)
      task_ref = Process.monitor(task_pid)

      Process.exit(task_pid, :kill)

      assert_receive {:DOWN, ^task_ref, :process, ^task_pid, :killed}

      assert_eventually(
        Process.whereis(task_name) not in [nil, task_pid] and
          Process.whereis(repo_name) not in [nil, repo_pid]
      )

      assert Process.whereis(registry_name) == registry_pid
    end

    test "stores shared defaults in persistent_term" do
      config = build_config()
      backend = {Mnemosyne.GraphBackends.InMemory, []}
      name = start_supervisor(config: config, backend: backend)

      defaults = MneSupervisor.get_defaults(name)
      assert defaults.config == config
      assert defaults.llm == Mnemosyne.MockLLM
      assert defaults.embedding == Mnemosyne.MockEmbedding
      assert defaults.notifier == Mnemosyne.Notifier.Noop
      assert defaults.backend == backend
    end

    test "accepts a custom notifier module" do
      defmodule CustomNotifier do
        @behaviour Mnemosyne.Notifier
        @impl true
        def notify(_repo_id, _event), do: :ok
      end

      name = start_supervisor(notifier: CustomNotifier)

      defaults = MneSupervisor.get_defaults(name)
      assert defaults.notifier == CustomNotifier
    end
  end

  describe "name derivation" do
    test "derives child names from supervisor name" do
      name = MyApp.Mnemosyne
      assert MneSupervisor.repo_registry_name(name) == MyApp.Mnemosyne.RepoRegistry
      assert MneSupervisor.repo_supervisor_name(name) == MyApp.Mnemosyne.RepoSupervisor
      assert MneSupervisor.task_supervisor_name(name) == MyApp.Mnemosyne.TaskSupervisor
    end
  end
end
