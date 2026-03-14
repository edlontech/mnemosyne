# Custom Adapters

Mnemosyne uses pluggable adapters for LLM and embedding calls. This guide covers writing your own adapters and configuring per-step model overrides.

## The LLM Behaviour

Implement `Mnemosyne.LLM` with two callbacks:

```elixir
defmodule MyApp.LLMAdapter do
  @behaviour Mnemosyne.LLM

  alias Mnemosyne.LLM.Response

  @impl true
  def chat(messages, opts) do
    {model, rest} = Keyword.pop!(opts, :model)

    # messages is a list of %{role: :system | :user | :assistant, content: String.t()}
    # Call your LLM provider here

    {:ok, %Response{
      content: response_text,
      model: model,
      usage: %{input_tokens: input, output_tokens: output}
    }}
  end

  @impl true
  def chat_structured(messages, schema, opts) do
    {model, rest} = Keyword.pop!(opts, :model)

    # schema is a Zoi schema for structured output
    # Return parsed data in the content field

    {:ok, %Response{
      content: parsed_map,
      model: model,
      usage: %{}
    }}
  end
end
```

### chat/2

Takes a list of messages and keyword options. The `:model` key is always present. Returns `{:ok, %LLM.Response{}}` with string content, or `{:error, %AdapterError{}}`.

Used by: mode classification, tag generation, subgoal inference, state summarization, reward estimation.

### chat_structured/3

Like `chat/2` but takes an additional Zoi schema and returns parsed structured data in the `content` field instead of raw text.

Used by: semantic extraction (returns `%{facts: [%{proposition, concepts}]}`), procedural extraction (returns `%{instructions: [%{intent, condition, instruction, expected_outcome}]}`).

## The Embedding Behaviour

Implement `Mnemosyne.Embedding` with two callbacks:

```elixir
defmodule MyApp.EmbeddingAdapter do
  @behaviour Mnemosyne.Embedding

  alias Mnemosyne.Embedding.Response

  @impl true
  def embed(text, opts) do
    {model, _rest} = Keyword.pop!(opts, :model)

    # Generate a single embedding vector
    vector = generate_embedding(model, text)

    {:ok, %Response{
      vectors: [vector],
      model: model,
      usage: %{input_tokens: token_count}
    }}
  end

  @impl true
  def embed_batch(texts, opts) do
    {model, _rest} = Keyword.pop!(opts, :model)

    # Generate embeddings for all texts
    vectors = Enum.map(texts, &generate_embedding(model, &1))

    {:ok, %Response{
      vectors: vectors,
      model: model,
      usage: %{}
    }}
  end
end
```

### embed/2

Embeds a single text. Returns `%Response{vectors: [vector]}` where `vector` is a list of floats.

### embed_batch/2

Embeds multiple texts. Returns `%Response{vectors: [vector1, vector2, ...]}` in the same order as input.

**Consistency requirement**: The same embedding model must be used across the entire knowledge graph. Mixing embedding models breaks cosine similarity comparisons.

## Built-in Adapters

### SycophantLLM / SycophantEmbedding

Wrap [Sycophant](https://github.com/edlontech/sycophant) for LLM and embedding calls. These are compiled conditionally -- they only exist when Sycophant is available as a dependency.

```elixir
llm: Mnemosyne.Adapters.SycophantLLM,
embedding: Mnemosyne.Adapters.SycophantEmbedding
```

### BumblebeeEmbedding

Runs embeddings locally using [Bumblebee](https://github.com/elixir-nx/bumblebee) models. No external API calls needed.

```elixir
embedding: Mnemosyne.Adapters.BumblebeeEmbedding
```

## Registration

Adapters are passed when starting the supervisor (shared defaults) or when opening a repo (per-repo override):

```elixir
# Shared defaults at supervisor level
{Mnemosyne.Supervisor,
  config: config,
  llm: MyApp.LLMAdapter,
  embedding: MyApp.EmbeddingAdapter}

# Per-repo override
Mnemosyne.open_repo("special-repo",
  backend: {Mnemosyne.GraphBackends.InMemory, []},
  llm: MyApp.SpecialLLMAdapter)
```

Per-session overrides are also supported:

```elixir
Mnemosyne.start_session("goal", repo: "my-repo", llm: MyApp.FastLLMAdapter)
```

## Per-Step Model Overrides

You can use different models for different pipeline steps without writing separate adapters. Configure overrides in `Mnemosyne.Config`:

```elixir
config = %Mnemosyne.Config{
  llm: %{model: "gpt-4o", opts: %{temperature: 0.7}},
  embedding: %{model: "text-embedding-3-small", opts: %{}},
  overrides: %{
    structuring: %{model: "gpt-4o-mini"},
    get_mode: %{model: "gpt-4o-mini", opts: %{temperature: 0.0}},
    get_plan: %{model: "gpt-4o-mini"},
    retrieval: %{opts: %{temperature: 0.0}}
  }
}
```

When a pipeline step has an override:
- The override's `:model` replaces the base model (if present)
- The override's `:opts` are merged on top of the base opts

This lets you use a cheap, fast model for simple classification steps and a powerful model for knowledge extraction.

## Error Handling

Adapters should return `{:error, %Mnemosyne.Errors.Framework.AdapterError{}}` on failure. The pipeline propagates these errors through the session state machine, moving the session to `:failed` where it can be retried.

```elixir
def chat(messages, opts) do
  case make_api_call(messages, opts) do
    {:ok, response} -> {:ok, to_response(response)}
    {:error, reason} -> {:error, AdapterError.exception(reason: reason)}
  end
end
```

## Next Steps

- [Getting Started](getting-started.md) - setting up adapters in the supervisor
- [Sessions and Episodes](sessions-and-episodes.md) - how adapters are used during extraction
- [Retrieval and Recall](retrieval-and-recall.md) - how adapters are used during recall
