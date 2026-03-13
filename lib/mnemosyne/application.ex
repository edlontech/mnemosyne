defmodule Mnemosyne.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    config = Application.get_all_env(:mnemosyne)

    children =
      if config[:storage] do
        [{Mnemosyne.Supervisor, config}]
      else
        []
      end

    children = children ++ dev_children()
    opts = [strategy: :one_for_one, name: Mnemosyne.AppSupervisor]
    Supervisor.start_link(children, opts)
  end

  defp dev_children do
    if System.get_env("TIDEWAVE_REPL") == "true" and Code.ensure_loaded?(Bandit) do
      ensure_tidewave_started()
      port = String.to_integer(System.get_env("TIDEWAVE_PORT", "10001"))
      [{Bandit, plug: Tidewave, port: port}]
    else
      []
    end
  end

  defp ensure_tidewave_started do
    case Application.ensure_all_started(:tidewave) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end
end
