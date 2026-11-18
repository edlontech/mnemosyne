# Benchmarks

## LongMemEval

[LongMemEval](https://github.com/xiaowu0162/LongMemEval) tests long-term chat memory with 500 questions, each with its own history of chat sessions. `longmemeval.exs` runs it against Mnemosyne and reports retrieval quality and answer accuracy.

### Running

From the repository root, with `OPENROUTER_API_KEY` and `OPENAI_API_KEY` set:

```bash
# Cheap smoke run: evidence sessions only, 3 questions
mix run benchmark/longmemeval.exs --variant oracle --limit 3 --run smoke

# Real run: 100 questions with full haystacks
mix run benchmark/longmemeval.exs --run baseline
```

The dataset is downloaded to `benchmark/data/` on first use (15 MB for `oracle`, 277 MB for `s`).

| Flag | Default | Meaning |
|---|---|---|
| `--variant` | `s` | `s` (about 115k tokens of history per question) or `oracle` (evidence sessions only) |
| `--limit` | `100` | Number of questions, taken in a fixed order (hash of `question_id`) |
| `--run` | the variant | Output directory name under `benchmark/runs/` |
| `--llm` | `openrouter:google/gemini-3-flash-preview` | Model for ingestion, recall and the reader |
| `--embedding` | `openai:text-embedding-3-small` | Embedding model |
| `--judge` | `openai:gpt-4o-2024-08-06` | Model that grades answers (the version upstream pins) |
| `--concurrency` | `2` | Questions processed in parallel |
| `--segmentation-threshold` | `0.3` | `Config.segmentation_threshold`; 0.3 fits `text-embedding-3-small`, where consecutive same-session subgoals score a median of 0.49 and random pairs 0.19 |

Model strings are Sycophant identifiers. Keep one `--run` per configuration or branch you want to compare, since a run directory is never reset.

### What it does per question

1. Opens a repo persisted at `runs/<run>/repos/<question_id>.dets`.
2. Ingests every haystack session as one `Mnemosyne.Trajectory`: the session id is the `source_id`, each user turn is an `observation` and the assistant reply its `action`, and the session date is the trajectory's `occurred_at`.
3. Calls `Mnemosyne.recall/3` with the question and `now:` set to the question date, using the default config.
4. Maps recalled nodes back to sessions with `Mnemosyne.get_sources/3` and scores them against `answer_session_ids`.
5. Answers the question from the recalled summaries and grades the answer with the upstream judge prompts.

### Resuming

A run can be stopped and restarted with the same command. Questions already in `results.jsonl` are skipped, and sessions already ingested return their stored receipt without any model call. A question that fails is logged and left out of the results, so the next invocation retries it.

### Output

`runs/<run>/results.jsonl` has one line per question. `runs/<run>/summary.json` and the printed table aggregate them overall, per question type, and for abstention questions.

| Metric | Definition |
|---|---|
| `accuracy` | Share of answers the judge accepted |
| `recall_any@k` | 1 if any gold session is among the top k retrieved sessions |
| `recall_all@k` | 1 if every gold session is among the top k |
| `ndcg@k` | Rank quality of gold sessions in the top k, using upstream's formula |
| `reader_recall` | Share of gold sessions behind the nodes the reasoner actually read (`reasoned_ids`) |
| `memory_tokens` | Size of the recalled summaries given to the reader, as characters / 4 |

Retrieved sessions are ranked by the score of their best `touched_nodes` entry. Retrieval metrics skip the 30 abstention questions, which have no evidence location. `usage_this_invocation` counts calls, tokens and cost per model for the current invocation only.

### Cost

Measured on a 3-question `oracle` run (6 sessions, about 21k tokens of chat): 219 LLM calls, 214k input and 32k output tokens, $0.20 with the default models, and about 40 seconds per session.

Measured on 2 `s` questions (90 sessions, about 246k tokens of chat): 3,018 LLM calls, $2.52, about 12 minutes of ingestion at the default concurrency, and one 142 MB repo file per question. Ingestion makes three calls per step (state, subgoal, reward) and up to three per trajectory segment (facts, procedures, return scoring).

Scaled by history size, plan for about $125 and 14 GB of disk per 100 questions, and about $630 for all 500.

### Differences from upstream

- The judge gets `max_tokens: 16` instead of 10, because OpenAI rejects values below 16.
- The reader prompt is upstream's "facts extracted from history chats" variant, fed with Mnemosyne's reasoned summaries instead of raw sessions.
- Retrieval is scored at session level only. Turn-level `has_answer` labels are not used.

### Known limits

- With the `oracle` variant every session is gold, so retrieval metrics are trivially 1.0. Only `s` measures retrieval.
- Dataset dates carry no time zone and are read as UTC.
- Changing how sessions are turned into trajectories changes their payload, so an existing run directory then reports source conflicts. Use a new `--run` name after such a change.
- `InMemory` recall scans every node, so recall time grows with haystack size.
