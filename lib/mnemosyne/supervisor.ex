defmodule Mnemosyne.Supervisor do
  @moduledoc """
  Top-level supervisor for the Mnemosyne runtime.

  Starts the process tree with `:rest_for_one` strategy:
  Registry -> TaskSupervisor -> MemoryStore -> SessionSupervisor.
  """
  use Supervisor

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    registry_name = registry_name(name)
    task_sup_name = task_supervisor_name(name)
    store_name = memory_store_name(name)
    session_sup_name = session_supervisor_name(name)

    memory_store_opts = [
      name: store_name,
      storage: Keyword.fetch!(opts, :storage),
      config: Keyword.fetch!(opts, :config),
      llm: Keyword.fetch!(opts, :llm),
      embedding: Keyword.fetch!(opts, :embedding),
      value_functions: Keyword.get(opts, :value_functions, %{}),
      task_supervisor: task_sup_name
    ]

    children = [
      {Registry, keys: :unique, name: registry_name},
      {Task.Supervisor, name: task_sup_name},
      {Mnemosyne.MemoryStore, memory_store_opts},
      {DynamicSupervisor, name: session_sup_name, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def registry_name(sup_name), do: Module.concat(sup_name, Registry)
  def task_supervisor_name(sup_name), do: Module.concat(sup_name, TaskSupervisor)
  def memory_store_name(sup_name), do: Module.concat(sup_name, MemoryStore)
  def session_supervisor_name(sup_name), do: Module.concat(sup_name, SessionSupervisor)
end
