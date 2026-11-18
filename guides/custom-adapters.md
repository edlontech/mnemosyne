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

`chat/2` returns string content. Mnemosyne uses it for reward inference. `chat_structured/3` receives a Zoi schema and returns parsed content; it is used for step annotation (state and subgoal), semantic, procedural, and return extraction, recall planning, multi-hop control and refinement, typed reasoning, intent merging, and semantic consolidation.

### Decision models

`evaluate/3` is an optional callback for decision models such as Jev or the OpenAI Decisions API, which answer typed questions with probabilities instead of generating text. Mnemosyne calls it only when `Mnemosyne.Config` sets `:decision`:

```elixir
config = %Mnemosyne.Config{
  llm: %{model: "openrouter:deepseek/deepseek-v4.1-flash", opts: %{}},
  embedding: %{model: "openai:text-embedding-3-small", opts: %{}},
  decision: %{model: "typesafe:jev-latest", opts: %{}}
}
```

The callback receives a shared `state` (a string, map or list), a map of question id to yes/no instructions, and the decision model opts. It returns a `Response` whose `content` maps every answered question id to the probability of "yes"; unanswered questions are left out.

```elixir
@impl true
def evaluate(state, questions, opts) do
  {model, provider_opts} = Keyword.pop!(opts, :model)

  case call_decision_provider(model, state, questions, provider_opts) do
    {:ok, probabilities, usage} ->
      {:ok, %Response{content: probabilities, model: model, usage: usage}}

    {:error, reason} ->
      {:error, AdapterError.exception(adapter: __MODULE__, operation: :evaluate, reason: reason)}
  end
end
```

With a decision model configured:

| Step | Without | With |
|------|---------|------|
| Reward scoring | one `chat` call per step | one request per window of steps |
| Fact extraction gate | every step is extracted | steps below `fact_gate_threshold` are skipped |
| Return scoring | one `chat_structured` call per segment | one request per segment |
| Hop control | one `chat_structured` call per hop | one request per hop, which also reranks and filters candidates |
| Final pool | not judged | judged once more before ranking |

The built-in Sycophant and ReqLLM adapters implement `evaluate/3`. Setting `:decision` with an adapter that does not implement it makes those calls raise.

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

## Usage and Cost Telemetry

Keep adapter callbacks and response structs unchanged. For repository-backed calls, Mnemosyne copies recognized values from `Response.usage` into the canonical terminal telemetry event; it does not add internal options to adapter callbacks. Existing custom adapters therefore remain compatible.

Recognized optional usage keys are:

| Category | Keys |
|---|---|
| Tokens | `:input_tokens`, `:output_tokens`, `:cache_creation_input_tokens`, `:cache_read_input_tokens`, `:reasoning_tokens` |
| Costs | `:input_cost`, `:output_cost`, `:cache_read_cost`, `:cache_write_cost`, `:reasoning_cost`, `:total_cost` |
| Currency | `:currency` |

Use non-negative integers for token counts, numbers for costs, and a string for currency. Nil and invalid values are omitted; valid zero values are preserved. Additional usage keys remain in the response but are not canonical telemetry fields.

Missing cost is unknown, not zero. Mnemosyne does not price calls, sum component costs, convert currencies, aggregate or persist costs, invoice, or enforce budgets.

Built-in adapter telemetry remains backward-compatible, but it is non-canonical for per-repository cost aggregation. Aggregate only `[:mnemosyne, :model, :call, :stop]` and `[:mnemosyne, :model, :call, :exception]` records; do not count adapter events as well.

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
| Episode | `annotate_steps`, `get_reward` | `chat_structured` for annotation; `chat` for reward |
| Structuring | `get_semantic`, `get_procedural`, `get_return` | `chat_structured` |
| Retrieval | `get_plan` | `chat_structured` |
| Hop control | `multi_hop_control`, `get_refined_query` | `chat_structured` |
| Reasoning | `reason_episodic`, `reason_semantic`, `reason_procedural` | `chat_structured` |
| Intent merger | `merge_intent` | `chat_structured` |
| Semantic consolidation | `merge_semantic` | `chat_structured` |

## Error Handling

Return `{:error, %Mnemosyne.Errors.Framework.AdapterError{}}` for expected provider failures rather than raising or pattern-matching on `{:ok, value}`. Wrap the provider reason as shown above, preserving it in `AdapterError.reason`. A failed ingestion returns the structured error to every coalesced caller; the caller still owns the complete trajectory and decides whether to retry it. No ingestion receipt is returned before backend commit.

## Built-in Adapters

- `Mnemosyne.Adapters.SycophantLLM` and `Mnemosyne.Adapters.SycophantEmbedding` wrap the optional Sycophant dependency.
- `Mnemosyne.Adapters.ReqLLM` and `Mnemosyne.Adapters.ReqLLMEmbedding` wrap the optional `req_llm` dependency.
- `Mnemosyne.Adapters.BumblebeeEmbedding` runs local Bumblebee embedding models.

### Using ReqLLM

Add `{:req_llm, "~> 1.22"}` to your application's dependencies, then select the adapters:

```elixir
{Mnemosyne.Supervisor,
  config: config,
  llm: Mnemosyne.Adapters.ReqLLM,
  embedding: Mnemosyne.Adapters.ReqLLMEmbedding}
```

Use ReqLLM model identifiers such as `"openai:gpt-4o-mini"` in `config.llm.model`
and `"openai:text-embedding-3-small"` in `config.embedding.model`, including per-step
model overrides. Either adapter can also be used independently. Configure provider
credentials through ReqLLM (for example, `OPENAI_API_KEY`), or pass `api_key` in the
model's `opts`. LLM options are forwarded unchanged, except `:step`, which is reserved
for adapter telemetry.

Both text and structured calls return `Mnemosyne.LLM.Response`. Structured output
is parsed with the supplied Zoi schema, restoring nested atom keys without enabling
scalar coercion that the schema did not request. Provider and validation failures
return `AdapterError` with the original reason. Usage and costs are preserved;
`cached_tokens` and `cache_creation_tokens` also populate Mnemosyne's
`cache_read_input_tokens` and `cache_creation_input_tokens` telemetry fields.

The embedding adapter supports single texts and batches, returning a list of vectors
in input order. It forwards options such as `dimensions` and always requests float
encoding and usage data. Its response uses the requested model identifier because
ReqLLM's embedding result does not include one. Embedding calls retain the existing
single-text length and successful batch-size telemetry, and wrap failures in `AdapterError`.

## Next Steps

- [Getting Started](getting-started.md)
- [Trajectory Ingestion](trajectory-ingestion.md)
- [Retrieval and Recall](retrieval-and-recall.md)
