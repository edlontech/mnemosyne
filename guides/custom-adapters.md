# Custom Adapters

Mnemosyne uses pluggable LLM and embedding adapters during blocking ingestion, recall, and maintenance operations.

## LLM Behaviour

Implement `Mnemosyne.LLM`:

```elixir
defmodule MyApp.LLMAdapter do
  @behaviour Mnemosyne.LLM

  alias Mnemosyne.Errors.Framework.AdapterError
  alias Mnemosyne.LLM.Response

  @impl true
  def chat(messages, opts) do
    {model, provider_opts} = Keyword.pop!(opts, :model)

    case call_provider(model, messages, provider_opts) do
      {:ok, text, usage} ->
        {:ok, %Response{content: text, model: model, usage: usage}}

      {:error, reason} ->
        {:error, AdapterError.exception(adapter: __MODULE__, operation: :chat, reason: reason)}
    end
  end

  @impl true
  def chat_structured(messages, schema, opts) do
    {model, provider_opts} = Keyword.pop!(opts, :model)

    case call_structured_provider(model, messages, schema, provider_opts) do
      {:ok, parsed, usage} ->
        {:ok, %Response{content: parsed, model: model, usage: usage}}

      {:error, reason} ->
        {:error,
         AdapterError.exception(
           adapter: __MODULE__,
           operation: :chat_structured,
           reason: reason
         )}
    end
  end
end
```

`chat/2` returns string content. Mnemosyne uses it for state and reward inference and initial recall mode/tag planning. `chat_structured/3` receives a Zoi schema and returns parsed content; it is used for subgoal, semantic, procedural, and return extraction, multi-hop control and refinement, typed reasoning, intent merging, and semantic consolidation.

## Embedding Behaviour

Implement `Mnemosyne.Embedding`:

```elixir
defmodule MyApp.EmbeddingAdapter do
  @behaviour Mnemosyne.Embedding

  alias Mnemosyne.Embedding.Response
  alias Mnemosyne.Errors.Framework.AdapterError

  @impl true
  def embed(text, opts) do
    {model, provider_opts} = Keyword.pop!(opts, :model)

    case generate_embedding(model, text, provider_opts) do
      {:ok, vector} ->
        {:ok, %Response{vectors: [vector], model: model, usage: %{}}}

      {:error, reason} ->
        {:error, AdapterError.exception(adapter: __MODULE__, operation: :embed, reason: reason)}
    end
  end

  @impl true
  def embed_batch(texts, opts) do
    {model, provider_opts} = Keyword.pop!(opts, :model)

    case generate_embeddings(model, texts, provider_opts) do
      {:ok, vectors} ->
        {:ok, %Response{vectors: vectors, model: model, usage: %{}}}

      {:error, reason} ->
        {:error,
         AdapterError.exception(adapter: __MODULE__, operation: :embed_batch, reason: reason)}
    end
  end
end
```

`embed_batch/2` must preserve input order. Use one compatible embedding model across a repository; mixing vector spaces invalidates cosine comparisons.

## Registration and Overrides

Configure shared defaults on the supervisor and optional repo defaults when opening a repo:

```elixir
{Mnemosyne.Supervisor,
  config: config,
  llm: MyApp.LLMAdapter,
  embedding: MyApp.EmbeddingAdapter}

Mnemosyne.open_repo("special-repo",
  backend: {Mnemosyne.GraphBackends.InMemory, []},
  llm: MyApp.SpecialLLMAdapter,
  embedding: MyApp.SpecialEmbeddingAdapter
)
```

Override execution for one complete ingestion by passing the trajectory to `ingest/3`:

```elixir
trajectory = %Mnemosyne.Trajectory{
  source_id: "task-42",
  goal: "Investigate cache invalidation",
  steps: [
    %{observation: "A stale entry was returned", action: "Traced invalidation events"}
  ],
  metadata: %{component: "cache"}
}

Mnemosyne.ingest("special-repo", trajectory,
  config: config,
  llm: MyApp.FastLLMAdapter,
  embedding: MyApp.EmbeddingAdapter,
  llm_opts: [temperature: 0.0]
)
```

The replacement config controls ordinary trajectory embedding calls, while `llm_opts` is merged into ingestion LLM calls where used. Per-ingestion `embedding_opts` currently reaches only write-time intent merging. These execution choices do not enter payload identity. Equal pending submissions coalesce under the first admitted call's choices, and equal persisted retries return the original receipt without invoking adapters again. Per-ingestion config replacement does not affect recall; recall uses the repository config and adapters.

## Per-Step Model Overrides

Use `Mnemosyne.Config.overrides` to select models or provider options by pipeline step:

```elixir
config = %Mnemosyne.Config{
  llm: %{model: "gpt-4o", opts: %{temperature: 0.7}},
  embedding: %{model: "text-embedding-3-small", opts: %{}},
  overrides: %{
    get_semantic: %{model: "gpt-4o-mini"},
    get_plan: %{model: "gpt-4o-mini", opts: %{temperature: 0.0}},
    reason_semantic: %{opts: %{temperature: 0.0}}
  }
}
```

An override model replaces the base model; override options merge over base options. Live override keys are:

| Stage | Keys | Callback |
|-------|------|----------|
| Episode | `get_state`, `get_subgoal`, `get_reward` | `chat` for state/reward; `chat_structured` for subgoal |
| Structuring | `get_state`, `get_semantic`, `get_procedural`, `get_return` | `chat` for state; otherwise `chat_structured` |
| Retrieval | `get_mode`, `get_plan` | `chat` |
| Hop control | `multi_hop_control`, `get_refined_query` | `chat_structured` |
| Reasoning | `reason_episodic`, `reason_semantic`, `reason_procedural` | `chat_structured` |
| Intent merger | `merge_intent` | `chat_structured` |
| Semantic consolidation | `merge_semantic` | `chat_structured` |

## Error Handling

Return `{:error, %Mnemosyne.Errors.Framework.AdapterError{}}` for expected provider failures rather than raising or pattern-matching on `{:ok, value}`. Wrap the provider reason as shown above, preserving it in `AdapterError.reason`. A failed ingestion returns the structured error to every coalesced caller; the caller still owns the complete trajectory and decides whether to retry it. No ingestion receipt is returned before backend commit.

## Built-in Adapters

- `Mnemosyne.Adapters.SycophantLLM` and `Mnemosyne.Adapters.SycophantEmbedding` wrap the optional Sycophant dependency.
- `Mnemosyne.Adapters.BumblebeeEmbedding` runs local Bumblebee embedding models.

## Next Steps

- [Getting Started](getting-started.md)
- [Trajectory Ingestion](trajectory-ingestion.md)
- [Retrieval and Recall](retrieval-and-recall.md)
