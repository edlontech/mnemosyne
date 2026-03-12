defmodule Mnemosyne.Config do
  @moduledoc """
  Unified configuration for Mnemosyne LLM and embedding settings.

  Holds default model configuration for LLM and embedding calls,
  plus per-step overrides that merge on top of defaults.
  """
  use ZoiDefstruct

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

  @doc "Loads and validates config from the `:mnemosyne` application environment."
  @spec from_env() :: {:ok, t()} | {:error, term()}
  def from_env do
    case Application.get_env(:mnemosyne, :config) do
      nil -> {:error, :no_config}
      raw -> Zoi.parse(t(), raw)
    end
  end
end
