defmodule Mnemosyne.Config do
  @moduledoc """
  Unified configuration for Mnemosyne LLM and embedding settings.

  Holds default model configuration for LLM and embedding calls,
  plus per-step overrides that merge on top of defaults.
  """
  use ZoiDefstruct

  alias Mnemosyne.Errors.Invalid.ConfigError

  defstruct(
    llm:
      Zoi.object(%{
        model: Zoi.string(),
        opts: Zoi.default(Zoi.map(), %{})
      }),
    embedding:
      Zoi.object(%{
        model: Zoi.string(),
        opts: Zoi.default(Zoi.map(), %{})
      }),
    overrides:
      Zoi.map(
        Zoi.atom(),
        Zoi.object(%{
          model: Zoi.optional(Zoi.string()),
          opts: Zoi.optional(Zoi.map())
        })
      )
      |> Zoi.default(%{})
  )

  @doc "Returns the LLM model and opts for the given pipeline step, applying any overrides."
  @spec resolve(t(), atom()) :: %{model: String.t(), opts: map()}
  def resolve(%__MODULE__{} = config, step) do
    base = %{model: config.llm.model, opts: config.llm.opts}

    case Map.get(config.overrides, step) do
      nil ->
        base

      override ->
        %{
          model: override[:model] || base.model,
          opts: Map.merge(base.opts, override[:opts] || %{})
        }
    end
  end

  @doc "Returns the embedding model and opts from the config."
  @spec resolve_embedding(t()) :: %{model: String.t(), opts: map()}
  def resolve_embedding(%__MODULE__{} = config) do
    %{model: config.embedding.model, opts: config.embedding.opts}
  end

  @doc "Returns LLM keyword opts for a pipeline step, merging overrides with base opts."
  @spec llm_opts(t() | nil, atom(), keyword()) :: keyword()
  def llm_opts(nil, _step, base_opts), do: base_opts

  def llm_opts(%__MODULE__{} = config, step, base_opts) do
    resolved = resolve(config, step)
    [model: resolved.model] ++ Map.to_list(resolved.opts) ++ base_opts
  end

  @doc "Returns embedding keyword opts from the config."
  @spec embedding_opts(t() | nil) :: keyword()
  def embedding_opts(nil), do: []

  def embedding_opts(%__MODULE__{} = config) do
    resolved = resolve_embedding(config)
    [model: resolved.model] ++ Map.to_list(resolved.opts)
  end

  @doc "Loads and validates config from the `:mnemosyne` application environment."
  @spec from_env() :: {:ok, t()} | {:error, ConfigError.t()}
  def from_env do
    case Application.get_env(:mnemosyne, :config) do
      nil -> {:error, ConfigError.exception(reason: :no_config)}
      raw -> Zoi.parse(t(), raw)
    end
  end
end
