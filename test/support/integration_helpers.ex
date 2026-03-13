defmodule Mnemosyne.IntegrationCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  @llm_model "openrouter:google/gemini-3-flash-preview"
  @embedding_model "intfloat/e5-base-v2"

  using do
    quote do
      @moduletag :integration
    end
  end

  setup_all _context do
    serving = build_serving()
    %{serving: serving, embedding_model: @embedding_model, llm_model: @llm_model}
  end

  setup context do
    api_key =
      case System.get_env("OPENROUTER_API_KEY") do
        nil ->
          raise ExUnit.AssertionError,
            message: "OPENROUTER_API_KEY not set, required for integration tests"

        key ->
          key
      end

    result = %{api_key: api_key}

    if tmp_dir = context[:tmp_dir] do
      start_supervisor(tmp_dir, api_key, context[:serving])
    end

    result
  end

  defp build_serving do
    default_backend()

    repo = {:hf, @embedding_model}
    {:ok, model_info} = Bumblebee.load_model(repo)
    {:ok, tokenizer} = Bumblebee.load_tokenizer(repo)

    Bumblebee.Text.text_embedding(model_info, tokenizer,
      compile: [batch_size: 4, sequence_length: 512],
      defn_options: [compiler: defn_compiler()]
    )
  end

  defp default_backend do
    case :os.type() do
      {:unix, :darwin} ->
        Nx.global_default_backend({EMLX.Backend, device: :cpu})

      _ ->
        Nx.global_default_backend(EXLA.Backend)
    end
  end

  defp defn_compiler do
    case :os.type() do
      {:unix, :darwin} -> EMLX
      _ -> EXLA
    end
  end

  defp start_supervisor(tmp_dir, api_key, serving) do
    {:ok, config} =
      Zoi.parse(Mnemosyne.Config.t(), %{
        llm: %{model: @llm_model, opts: %{api_key: api_key}},
        embedding: %{model: @embedding_model, opts: %{serving: serving}}
      })

    dets_path = Path.join(tmp_dir, "integration_test.dets")

    opts = [
      backend:
        {Mnemosyne.GraphBackends.InMemory,
         persistence: {Mnemosyne.GraphBackends.Persistence.DETS, path: dets_path}},
      config: config,
      llm: Mnemosyne.Adapters.SycophantLLM,
      embedding: Mnemosyne.Adapters.BumblebeeEmbedding
    ]

    ExUnit.Callbacks.start_supervised!({Mnemosyne.Supervisor, opts})
  end
end
