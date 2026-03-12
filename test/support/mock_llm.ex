defmodule Mnemosyne.MockLLM do
  @moduledoc false
  @behaviour Mnemosyne.LLM

  alias Mnemosyne.LLM.Response

  @impl true
  def chat(_messages, _opts \\ []) do
    {:ok,
     %Response{
       content: "mock response",
       model: "mock:test",
       usage: %{input_tokens: 10, output_tokens: 5}
     }}
  end

  @impl true
  def chat_structured(_messages, _schema, _opts \\ []) do
    {:ok,
     %Response{content: %{}, model: "mock:test", usage: %{input_tokens: 10, output_tokens: 5}}}
  end
end
