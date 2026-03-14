defmodule Mnemosyne.Config do
  use ZoiDefstruct

  alias Mnemosyne.Errors.Invalid.ConfigError

  @llm_schema Zoi.object(
                %{
                  model:
                    Zoi.string(
                      description:
                        "The LLM model identifier (e.g. `\"gpt-4o\"`, `\"claude-sonnet-4-20250514\"`)"
                    ),
                  opts:
                    Zoi.default(Zoi.map(), %{},
                      description:
                        "Additional options forwarded to the LLM adapter (temperature, max_tokens, etc.)"
                    )
                },
                description: "Default LLM configuration applied to all pipeline steps"
              )

  @embedding_schema Zoi.object(
                      %{
                        model:
                          Zoi.string(
                            description:
                              "The embedding model identifier (e.g. `\"text-embedding-3-small\"`, `\"e5-base-v2\"`)"
                          ),
                        opts:
                          Zoi.default(Zoi.map(), %{},
                            description: "Additional options forwarded to the embedding adapter"
                          )
                      },
                      description: "Default embedding model configuration for vector generation"
                    )

  @backend_schema Zoi.object(
                    %{
                      module: Zoi.atom(description: "GraphBackend implementation module"),
                      opts:
                        Zoi.default(Zoi.map(), %{},
                          description: "Options passed to backend init/1"
                        )
                    },
                    description: "Graph backend configuration"
                  )

  @override_schema Zoi.map(
                     Zoi.atom(),
                     Zoi.object(%{
                       model:
                         Zoi.optional(
                           Zoi.string(description: "Override model for this pipeline step")
                         ),
                       opts:
                         Zoi.optional(
                           Zoi.map(description: "Override options merged with default LLM opts")
                         )
                     }),
                     description: "Per-step LLM overrides keyed by pipeline step atom"
                   )
                   |> Zoi.default(%{})

  @config_schema Zoi.object(%{
                   llm: @llm_schema,
                   embedding: @embedding_schema,
                   overrides: @override_schema,
                   backend: Zoi.optional(@backend_schema),
                   intent_merge_threshold:
                     Zoi.default(Zoi.float(), 0.8,
                       description:
                         "Cosine similarity threshold above which incoming intents are merged via LLM rewrite"
                     ),
                   intent_identity_threshold:
                     Zoi.default(Zoi.float(), 0.95,
                       description:
                         "Cosine similarity threshold above which incoming intents are silently deduplicated"
                     )
                 })

  defstruct(
    llm: @llm_schema,
    embedding: @embedding_schema,
    overrides: @override_schema,
    backend: Zoi.optional(@backend_schema),
    intent_merge_threshold:
      Zoi.default(Zoi.float(), 0.8,
        description:
          "Cosine similarity threshold above which incoming intents are merged via LLM rewrite"
      ),
    intent_identity_threshold:
      Zoi.default(Zoi.float(), 0.95,
        description:
          "Cosine similarity threshold above which incoming intents are silently deduplicated"
      )
  )

  @moduledoc """
  Unified configuration for Mnemosyne LLM and embedding settings.

  Holds default model configuration for LLM and embedding calls,
  plus per-step overrides that merge on top of defaults. Configuration
  is validated at load time using Zoi schemas to catch misconfiguration early.

  ## Fields

  #{Zoi.describe(@config_schema)}

  ## Override Resolution

  When a pipeline step (e.g. `:structuring`, `:retrieval`) has an entry in
  `:overrides`, the override's `:model` replaces the default and its `:opts`
  are deep-merged with the base LLM opts. This lets you use a cheaper model
  for simple extraction steps while keeping a powerful model for reasoning.

  ## Examples

  Minimal configuration with defaults:

      config = %Mnemosyne.Config{
        llm: %{model: "gpt-4o", opts: %{}},
        embedding: %{model: "text-embedding-3-small", opts: %{}}
      }

  With per-step overrides:

      config = %Mnemosyne.Config{
        llm: %{model: "gpt-4o", opts: %{temperature: 0.7}},
        embedding: %{model: "text-embedding-3-small", opts: %{}},
        overrides: %{
          structuring: %{model: "gpt-4o-mini"},
          retrieval: %{opts: %{temperature: 0.0}}
        }
      }

  Loading from application environment:

      # In config/config.exs
      config :mnemosyne, :config,
        llm: %{model: "gpt-4o", opts: %{temperature: 0.7}},
        embedding: %{model: "text-embedding-3-small", opts: %{}}

      # At runtime
      {:ok, config} = Mnemosyne.Config.from_env()
  """

  @doc """
  Returns the LLM model and opts for the given pipeline step, applying any overrides.

  Looks up the `step` atom in `config.overrides`. If an override exists, its
  `:model` replaces the base model (when present) and its `:opts` are merged
  on top of the base opts. When no override exists, the base LLM config is
  returned as-is.

  ## Examples

      iex> config = %Mnemosyne.Config{
      ...>   llm: %{model: "gpt-4o", opts: %{temperature: 0.7}},
      ...>   embedding: %{model: "e5-base-v2", opts: %{}},
      ...>   overrides: %{structuring: %{model: "gpt-4o-mini"}}
      ...> }
      iex> Mnemosyne.Config.resolve(config, :structuring)
      %{model: "gpt-4o-mini", opts: %{temperature: 0.7}}
      iex> Mnemosyne.Config.resolve(config, :retrieval)
      %{model: "gpt-4o", opts: %{temperature: 0.7}}
  """
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

  @doc """
  Returns the embedding model and opts from the config.

  Unlike `resolve/2`, embeddings have no per-step overrides since the same
  embedding model must be used consistently across the entire knowledge graph
  to keep vector spaces comparable.
  """
  @spec resolve_embedding(t()) :: %{model: String.t(), opts: map()}
  def resolve_embedding(%__MODULE__{} = config) do
    %{model: config.embedding.model, opts: config.embedding.opts}
  end

  @doc """
  Returns LLM keyword opts for a pipeline step, merging overrides with base opts.

  Resolves the model and opts for the given `step`, then flattens the result
  into a keyword list suitable for passing directly to an LLM adapter call.
  The `base_opts` (typically pipeline-specific options like prompt messages)
  are appended after the resolved config options.

  Returns `base_opts` unchanged when config is `nil`, allowing callers to
  work without configuration.
  """
  @spec llm_opts(t() | nil, atom(), keyword()) :: keyword()
  def llm_opts(nil, _step, base_opts), do: base_opts

  def llm_opts(%__MODULE__{} = config, step, base_opts) do
    resolved = resolve(config, step)
    [model: resolved.model] ++ Map.to_list(resolved.opts) ++ base_opts
  end

  @doc """
  Returns embedding keyword opts from the config as a flat keyword list.

  Returns an empty list when config is `nil`, allowing callers to work
  without configuration.
  """
  @spec embedding_opts(t() | nil) :: keyword()
  def embedding_opts(nil), do: []

  def embedding_opts(%__MODULE__{} = config) do
    resolved = resolve_embedding(config)
    [model: resolved.model] ++ Map.to_list(resolved.opts)
  end

  @doc """
  Loads and validates config from the `:mnemosyne` application environment.

  Reads the `:config` key under the `:mnemosyne` application and validates it
  against the Zoi schema. Returns `{:error, ConfigError}` when the key is
  missing or the data fails validation.

  ## Examples

      # When configured:
      {:ok, %Mnemosyne.Config{}} = Mnemosyne.Config.from_env()

      # When missing:
      {:error, %Mnemosyne.Errors.Invalid.ConfigError{reason: :no_config}} = Mnemosyne.Config.from_env()
  """
  @spec from_env() :: {:ok, t()} | {:error, ConfigError.t()}
  def from_env do
    case Application.get_env(:mnemosyne, :config) do
      nil -> {:error, ConfigError.exception(reason: :no_config)}
      raw -> Zoi.parse(t(), raw)
    end
  end
end
