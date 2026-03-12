defmodule Mnemosyne.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # Starts a worker by calling: Mnemosyne.Worker.start_link(arg)
        # {Mnemosyne.Worker, arg}
      ] ++ dev_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Mnemosyne.Supervisor]
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
