defmodule Mnemosyne.IntegrationHelpers do
  @moduledoc false

  @serving_name Mnemosyne.IntegrationServing
  @llm_model "google/gemini-2.0-flash-001"
  @embedding_model "Qwen/Qwen3-Embedding-0.6B"

  def serving_name, do: @serving_name
  def llm_model, do: @llm_model

  def ensure_openrouter_key! do
    case System.get_env("OPENROUTER_API_KEY") do
      nil -> raise ExUnit.AssertionError, message: "OPENROUTER_API_KEY not set, skipping"
      key -> key
    end
  end

  def setup_serving do
    if Process.whereis(@serving_name) do
      :already_running
    else
      repo = {:hf, @embedding_model}
      {:ok, model_info} = Bumblebee.load_model(repo)
      {:ok, tokenizer} = Bumblebee.load_tokenizer(repo)

      serving =
        Bumblebee.Text.text_embedding(model_info, tokenizer,
          compile: [batch_size: 4, sequence_length: 512],
          defn_options: [compiler: EXLA]
        )

      {:ok, _pid} = Nx.Serving.start_link(serving: serving, name: @serving_name)
      :started
    end
  end

  def build_config(api_key) do
    Zoi.parse(Mnemosyne.Config.t(), %{
      llm: %{model: @llm_model, opts: %{api_key: api_key}},
      embedding: %{model: @embedding_model, opts: %{serving: @serving_name}}
    })
  end

  def start_supervisor(tmp_dir, api_key) do
    {:ok, config} = build_config(api_key)
    dets_path = Path.join(tmp_dir, "integration_test.dets") |> String.to_charlist()

    opts = [
      storage: {Mnemosyne.Storage.DETS, path: dets_path},
      config: config,
      llm: Mnemosyne.Adapters.SycophantLLM,
      embedding: Mnemosyne.Adapters.BumblebeeEmbedding
    ]

    import ExUnit.Callbacks
    start_supervised!({Mnemosyne.Supervisor, opts})
  end
end
