defmodule Mnemosyne.Supervisor do
  @moduledoc """
  Top-level supervisor for the Mnemosyne runtime.

  Starts the process tree with `:rest_for_one` strategy:
  SessionRegistry -> RepoRegistry -> TaskSupervisor -> RepoSupervisor -> SessionSupervisor.

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
    registry_name = registry_name(name)
    repo_registry_name = repo_registry_name(name)
    task_sup_name = task_supervisor_name(name)
    repo_sup_name = repo_supervisor_name(name)
    session_sup_name = session_supervisor_name(name)

    defaults = %{
      config: Keyword.fetch!(opts, :config),
      llm: Keyword.fetch!(opts, :llm),
      embedding: Keyword.fetch!(opts, :embedding),
      notifier: Keyword.get(opts, :notifier, Mnemosyne.Notifier.Noop)
    }

    :persistent_term.put({__MODULE__, name, :defaults}, defaults)

    children = [
      {Registry, keys: :unique, name: registry_name},
      {Registry, keys: :unique, name: repo_registry_name},
      {Task.Supervisor, name: task_sup_name},
      {DynamicSupervisor, name: repo_sup_name, strategy: :one_for_one},
      {DynamicSupervisor, name: session_sup_name, strategy: :one_for_one}
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
          notifier: module()
        }
  def get_defaults(sup_name \\ __MODULE__) do
    :persistent_term.get({__MODULE__, sup_name, :defaults})
  end

  @doc "Derives the session Registry name for the given supervisor."
  @spec registry_name(module()) :: module()
  def registry_name(sup_name), do: Module.concat(sup_name, Registry)

  @doc "Derives the repo Registry name for the given supervisor."
  @spec repo_registry_name(module()) :: module()
  def repo_registry_name(sup_name), do: Module.concat(sup_name, RepoRegistry)

  @doc "Derives the TaskSupervisor name for the given supervisor."
  @spec task_supervisor_name(module()) :: module()
  def task_supervisor_name(sup_name), do: Module.concat(sup_name, TaskSupervisor)

  @doc "Derives the RepoSupervisor name for the given supervisor."
  @spec repo_supervisor_name(module()) :: module()
  def repo_supervisor_name(sup_name), do: Module.concat(sup_name, RepoSupervisor)

  @doc "Derives the SessionSupervisor name for the given supervisor."
  @spec session_supervisor_name(module()) :: module()
  def session_supervisor_name(sup_name), do: Module.concat(sup_name, SessionSupervisor)
end
