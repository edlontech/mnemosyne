if Code.ensure_loaded?(Sycophant) do
  defmodule Mnemosyne.Adapters.SycophantLLM do
    @moduledoc """
    LLM adapter backed by Sycophant.

    Translates between the `Mnemosyne.LLM` behaviour and Sycophant's
    `generate_text/3` and `generate_object/4` APIs.
    """
    @behaviour Mnemosyne.LLM

    alias Mnemosyne.LLM.Response
    alias Sycophant.Message

    @impl true
    def chat(messages, opts) do
      {model, sycophant_opts} = Keyword.pop!(opts, :model)
      syc_messages = Enum.map(messages, &to_sycophant_message/1)

      case Sycophant.generate_text(model, syc_messages, sycophant_opts) do
        {:ok, response} -> {:ok, to_response(response, :text)}
        {:error, _} = err -> err
      end
    end

    @impl true
    def chat_structured(messages, schema, opts) do
      {model, sycophant_opts} = Keyword.pop!(opts, :model)
      syc_messages = Enum.map(messages, &to_sycophant_message/1)

      case Sycophant.generate_object(model, syc_messages, schema, sycophant_opts) do
        {:ok, response} -> {:ok, to_response(response, :object)}
        {:error, _} = err -> err
      end
    end

    defp to_sycophant_message(%{role: :system, content: content}), do: Message.system(content)
    defp to_sycophant_message(%{role: :user, content: content}), do: Message.user(content)

    defp to_sycophant_message(%{role: :assistant, content: content}),
      do: Message.assistant(content)

    defp to_response(response, :text) do
      %Response{
        content: response.text,
        model: response.model,
        usage: extract_usage(response.usage)
      }
    end

    defp to_response(response, :object) do
      %Response{
        content: response.object,
        model: response.model,
        usage: extract_usage(response.usage)
      }
    end

    defp extract_usage(nil), do: %{}

    defp extract_usage(usage) do
      %{input_tokens: usage.input_tokens, output_tokens: usage.output_tokens}
    end
  end
end
