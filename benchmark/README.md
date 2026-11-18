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
| `--llm` | `openai:gpt-6-luna` | Model for ingestion, recall and the reader |
| `--embedding` | `openai:text-embedding-3-small` | Embedding model |
| `--judge` | `openai:gpt-6-luna` | Model that grades answers, at low reasoning effort. Upstream pins `gpt-4o-2024-08-06`, so accuracy is not directly comparable to published numbers |
| `--decision` | none | Decision model (`Config.decision`), e.g. `typesafe:jev-latest`. Unset runs the LLM prompts it would replace |
| `--concurrency` | `2` | Questions processed in parallel |
| `--reasoning-effort` | `none` | Reasoning effort for `--llm` (`none`, `minimal`, `low`, `medium`, `high`). With `openrouter:deepseek/deepseek-v4.1-flash`, `low` still spent about 1,000 output tokens per call and hit the 60-second task timeout |
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
