defmodule Mnemosyne.TestNotifier do
  @moduledoc false

  @behaviour Mnemosyne.Notifier

  @table __MODULE__

  def setup do
    try do
      :ets.new(@table, [:bag, :public, :named_table])
    rescue
      ArgumentError -> :ok
    end

    :ets.delete_all_objects(@table)
    :ok
  end

  def events do
    :ets.tab2list(@table)
    |> Enum.map(fn {_repo_id, event} -> event end)
  end

  def events(repo_id) do
    :ets.lookup(@table, repo_id)
    |> Enum.map(fn {_repo_id, event} -> event end)
  end

  @impl true
  def notify(repo_id, event) do
    :ets.insert(@table, {repo_id, event})
    :ok
  end
end
