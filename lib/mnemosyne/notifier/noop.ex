defmodule Mnemosyne.Notifier.Noop do
  @moduledoc """
  No-op notifier that discards all events.
  """

  @behaviour Mnemosyne.Notifier

  @impl true
  def notify(_repo_id, _event), do: :ok
end
