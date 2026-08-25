defmodule Mnemosyne.Supervisor do
  @moduledoc """
  Top-level supervisor for the Mnemosyne runtime.

  Starts RepoRegistry, TaskSupervisor, and RepoSupervisor with a `:rest_for_one` strategy.

  Shared defaults (config, LLM adapter, embedding adapter, notifier) are stored
  in `:persistent_term` and applied to each repo opened via `Mnemosyne.open_repo/2`.
  """
  use Supervisor

  @doc false
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    repo_registry_name = repo_registry_name(name)
    task_sup_name = task_supervisor_name(name)
    repo_sup_name = repo_supervisor_name(name)

    defaults = %{
      config: Keyword.fetch!(opts, :config),
      llm: Keyword.fetch!(opts, :llm),
      embedding: Keyword.fetch!(opts, :embedding),
      notifier: Keyword.get(opts, :notifier, Mnemosyne.Notifier.Noop),
      backend: Keyword.get(opts, :backend)
    }

    :persistent_term.put({__MODULE__, name, :defaults}, defaults)

    children = [
      {Registry, keys: :unique, name: repo_registry_name},
      {Task.Supervisor, name: task_sup_name},
      {DynamicSupervisor, name: repo_sup_name, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Returns shared defaults (config, LLM adapter, embedding adapter)
  for the given supervisor instance.
  """
  @spec get_defaults(module()) :: %{
          config: term(),
          llm: module(),
          embedding: module(),
          notifier: module(),
          backend: term()
        }
  def get_defaults(sup_name \\ __MODULE__) do
    :persistent_term.get({__MODULE__, sup_name, :defaults})
  end

  @doc "Derives the repo Registry name for the given supervisor."
  @spec repo_registry_name(module()) :: module()
  def repo_registry_name(sup_name), do: Module.concat(sup_name, RepoRegistry)

  @doc "Derives the TaskSupervisor name for the given supervisor."
  @spec task_supervisor_name(module()) :: module()
  def task_supervisor_name(sup_name), do: Module.concat(sup_name, TaskSupervisor)

  @doc "Derives the RepoSupervisor name for the given supervisor."
  @spec repo_supervisor_name(module()) :: module()
  def repo_supervisor_name(sup_name), do: Module.concat(sup_name, RepoSupervisor)
end
