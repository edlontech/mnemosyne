defmodule Mnemosyne.MockLLM do
  @moduledoc false
  @behaviour Mnemosyne.LLM

  @impl true
  def chat(_messages, _opts \\ []) do
    {:ok, "mock response"}
  end
end
