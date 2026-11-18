defmodule LongMemEval do
  @moduledoc """
  LongMemEval harness for Mnemosyne.

  For each question it ingests the haystack sessions into a dedicated repo,
  recalls memory for the question, scores session-level retrieval against the
  gold evidence sessions, then answers from the recalled memory and grades the
  answer with the upstream LongMemEval judge prompts.

  Run from the repository root:

      mix run benchmark/longmemeval.exs --variant oracle --limit 3 --run smoke

  See `benchmark/README.md` for flags, outputs and metric definitions.
  """

  alias Mnemosyne.Adapters.SycophantEmbedding
  alias Mnemosyne.Adapters.SycophantLLM
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.GraphBackends.Persistence.DETS
  alias Mnemosyne.Trajectory

  @dir __DIR__
  @base_url "https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned/resolve/main/"
  @files %{"s" => "longmemeval_s_cleaned.json", "oracle" => "longmemeval_oracle.json"}

  @flags [
    variant: :string,
    limit: :integer,
    run: :string,
    llm: :string,
    embedding: :string,
    judge: :string,
    concurrency: :integer
  ]

  @defaults [
    variant: "s",
    limit: 100,
    llm: "openrouter:google/gemini-3-flash-preview",
    embedding: "openai:text-embedding-3-small",
    judge: "openai:gpt-4o-2024-08-06",
    concurrency: 2
  ]

  @ks [1, 3, 5, 10]
  @session_concurrency 4
  @ingest_attempts 3
  @none "(none)"

  @reader "I will give you several facts extracted from history chats between you and a user. " <>
            "Please answer the question based on the relevant facts."

  @contains "I will give you a question, a correct answer, and a response from a model. " <>
              "Please answer yes if the response contains the correct answer. Otherwise, answer no. "

  @equivalent @contains <>
                "If the response is equivalent to the correct answer or contains all the intermediate " <>
                "steps to get the correct answer, you should also answer yes. If the response only " <>
                "contains a subset of the information required by the answer, answer no. "

  @is_correct "Is the model response correct?"

  @doc "Runs the benchmark with command line flags and prints a summary."
  @spec main([String.t()]) :: :ok
  def main(argv) do
    {flags, []} = OptionParser.parse!(argv, strict: @flags)
    opts = Keyword.merge(@defaults, flags)
    run = opts[:run] || opts[:variant]
    run_dir = Path.join([@dir, "runs", run])
    results_path = Path.join(run_dir, "results.jsonl")
    File.mkdir_p!(Path.join(run_dir, "repos"))
    Logger.configure(level: :warning)

    questions =
      opts[:variant]
      |> load()
      |> Enum.sort_by(&:erlang.phash2(&1["question_id"]))
      |> Enum.take(opts[:limit])

    done = results_path |> read_rows() |> MapSet.new(& &1["question_id"])
    pending = Enum.reject(questions, &(&1["question_id"] in done))
    IO.puts("run #{run}: #{length(pending)} of #{length(questions)} questions to run")

    usage = start(opts)
    {:ok, tasks} = Task.Supervisor.start_link()
    ctx = %{run_dir: run_dir, llm: opts[:llm], judge: opts[:judge]}

    stream =
      Task.Supervisor.async_stream_nolink(tasks, pending, &run_question(&1, ctx),
        max_concurrency: opts[:concurrency],
        timeout: :infinity
      )

    pending
    |> Stream.zip(stream)
    |> Enum.each(fn
      {_question, {:ok, {:ok, row}}} ->
        File.write!(results_path, [JSON.encode!(row), "\n"], [:append])

        IO.puts(
          "#{row["question_id"]} #{row["question_type"]} correct=#{row["correct"]} " <>
            "ingest=#{div(row["ingest_ms"], 1000)}s recall=#{div(row["recall_ms"], 1000)}s"
        )

      {question, {_, failure}} ->
        IO.puts(:stderr, "#{question["question_id"]} failed: #{inspect(failure, limit: 20)}")
    end)

    ids = MapSet.new(questions, & &1["question_id"])
    rows = results_path |> read_rows() |> Enum.filter(&(&1["question_id"] in ids))

    summary = %{
      "run" => run,
      "config" => Map.new(opts),
      "overall" => summarize(rows),
      "abstention" => summarize(Enum.filter(rows, & &1["abstention"])),
      "by_type" =>
        rows
        |> Enum.group_by(& &1["question_type"])
        |> Map.new(fn {type, group} -> {type, summarize(group)} end),
      "usage_this_invocation" => Agent.get(usage, & &1)
    }

    File.write!(Path.join(run_dir, "summary.json"), JSON.encode!(summary))
    print(summary)
  end

  @doc false
  def track_usage(_event, _measurements, metadata, agent) do
    usage = metadata[:usage] || %{}

    add = %{
      calls: 1,
      input_tokens: usage[:input_tokens] || 0,
      output_tokens: usage[:output_tokens] || 0,
      cost: usage[:total_cost] || 0.0
    }

    Agent.update(agent, fn acc ->
      Map.update(acc, metadata.model, add, &Map.merge(&1, add, fn _key, a, b -> a + b end))
    end)
  end

  defp start(opts) do
    {:ok, config} =
      Zoi.parse(Mnemosyne.Config.t(), %{
        llm: %{model: opts[:llm]},
        embedding: %{model: opts[:embedding]}
      })

    {:ok, _pid} =
      Mnemosyne.Supervisor.start_link(
        config: config,
        llm: SycophantLLM,
        embedding: SycophantEmbedding
      )

    {:ok, usage} = Agent.start_link(fn -> %{} end)

    :ok =
      :telemetry.attach_many(
        "longmemeval-usage",
        [[:sycophant, :request, :stop], [:sycophant, :embedding, :stop]],
        &__MODULE__.track_usage/4,
        usage
      )

    usage
  end

  defp load(variant) do
    file = Map.fetch!(@files, variant)
    path = Path.join([@dir, "data", file])

    if not File.exists?(path) do
      File.mkdir_p!(Path.dirname(path))
      IO.puts("downloading #{file}")
      {_output, 0} = System.cmd("curl", ["-fL", "-o", path <> ".part", @base_url <> file])
      File.rename!(path <> ".part", path)
    end

    path |> File.read!() |> JSON.decode!()
  end

  defp read_rows(path) do
    case File.read(path) do
      {:ok, body} -> body |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      {:error, :enoent} -> []
    end
  end

  defp run_question(question, ctx) do
    repo = question["question_id"]
    path = Path.join([ctx.run_dir, "repos", repo <> ".dets"])
    {:ok, _pid} = Mnemosyne.open_repo(repo, backend: {InMemory, persistence: {DETS, path: path}})

    try do
      with {ingest_us, :ok} <- :timer.tc(fn -> ingest_sessions(repo, question) end),
           {recall_us, {:ok, recall}} <-
             :timer.tc(fn ->
               Mnemosyne.recall(repo, question["question"],
                 now: datetime(question["question_date"])
               )
             end),
           memory = memory_text(recall.reasoned),
           {:ok, hypothesis} <- chat(ctx.llm, reader_prompt(memory, question), []),
           # Upstream asks for 10 tokens; OpenAI now rejects anything below 16.
           {:ok, verdict} <- chat(ctx.judge, judge_prompt(question, hypothesis), max_tokens: 16) do
        abstention = String.ends_with?(repo, "_abs")
        gold = question["answer_session_ids"]

        ranked =
          recall.touched_nodes
          |> Enum.sort_by(& &1.score, :desc)
          |> Enum.map(& &1.id)
          |> sessions(repo)

        reasoned = recall.reasoned_ids |> Map.values() |> List.flatten() |> sessions(repo)

        {:ok,
         %{
           "question_id" => repo,
           "question_type" => question["question_type"],
           "abstention" => abstention,
           "mode" => recall.trace.mode,
           "gold_sessions" => gold,
           "ranked_sessions" => Enum.take(ranked, Enum.max(@ks)),
           "reasoned_sessions" => reasoned,
           "retrieval" => if(abstention, do: nil, else: retrieval(ranked, reasoned, gold)),
           "memory" => memory,
           "memory_tokens" => div(String.length(memory), 4),
           "answer" => to_string(question["answer"]),
           "hypothesis" => hypothesis,
           "correct" => String.contains?(String.downcase(verdict), "yes"),
           "ingest_ms" => div(ingest_us, 1000),
           "recall_ms" => div(recall_us, 1000)
         }}
      else
        {_us, {:error, reason}} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    after
      Mnemosyne.close_repo(repo)
    end
  end

  defp ingest_sessions(repo, question) do
    [question["haystack_session_ids"], question["haystack_dates"], question["haystack_sessions"]]
    |> Enum.zip()
    |> Enum.map(&trajectory/1)
    |> Enum.reject(&(&1.steps == []))
    |> Task.async_stream(&ingest(repo, &1, @ingest_attempts),
      max_concurrency: @session_concurrency,
      timeout: :infinity
    )
    |> Enum.find_value(:ok, fn
      {:ok, {:ok, _receipt}} -> nil
      {:ok, {:error, reason}} -> {:error, reason}
    end)
  end

  defp ingest(repo, trajectory, attempts) do
    case Mnemosyne.ingest(repo, trajectory) do
      {:error, _reason} when attempts > 1 ->
        Process.sleep(5_000)
        ingest(repo, trajectory, attempts - 1)

      result ->
        result
    end
  end

  defp trajectory({session_id, date, turns}) do
    %Trajectory{
      source_id: session_id,
      goal: "Chat session between a user and an assistant",
      occurred_at: datetime(date),
      steps: steps(turns)
    }
  end

  # Dataset dates look like "2023/04/10 (Mon) 07:43" and carry no zone; UTC is assumed.
  defp datetime(date) do
    [year, month, day, hour, minute] =
      ~r"^(\d+)/(\d+)/(\d+) \(\w+\) (\d+):(\d+)$"
      |> Regex.run(date, capture: :all_but_first)
      |> Enum.map(&String.to_integer/1)

    DateTime.new!(Date.new!(year, month, day), Time.new!(hour, minute, 0))
  end

  defp steps(turns) do
    turns
    |> Enum.chunk_by(& &1["role"])
    |> Enum.map(fn [%{"role" => role} | _] = run ->
      {role, text(Enum.map_join(run, "\n", & &1["content"]))}
    end)
    |> pair()
  end

  defp pair([{"user", said}, {"assistant", reply} | rest]),
    do: [%{observation: said, action: reply} | pair(rest)]

  defp pair([{"user", said} | rest]), do: [%{observation: said, action: @none} | pair(rest)]

  defp pair([{"assistant", reply} | rest]),
    do: [%{observation: @none, action: reply} | pair(rest)]

  defp pair([]), do: []

  defp text(content), do: if(String.trim(content) == "", do: @none, else: content)

  defp sessions(node_ids, repo) do
    node_ids
    |> Enum.flat_map(fn id ->
      {:ok, sources} = Mnemosyne.get_sources(repo, [id])
      Enum.map(sources, & &1.episode_id)
    end)
    |> Enum.uniq()
  end

  defp retrieval(ranked, reasoned, gold) do
    per_k =
      for k <- @ks,
          top = Enum.take(ranked, k),
          {name, value} <- [
            {"recall_any", hit(Enum.any?(gold, &(&1 in top)))},
            {"recall_all", hit(Enum.all?(gold, &(&1 in top)))},
            {"ndcg", ndcg(top, gold, k)}
          ],
          into: %{} do
        {"#{name}@#{k}", value}
      end

    Map.put(per_k, "reader_recall", Enum.count(gold, &(&1 in reasoned)) / length(gold))
  end

  defp hit(true), do: 1.0
  defp hit(false), do: 0.0

  defp ndcg(top, gold, k) do
    dcg =
      top
      |> Enum.with_index(1)
      |> Enum.sum_by(fn {id, rank} -> if id in gold, do: weight(rank), else: 0.0 end)

    dcg / Enum.sum_by(1..min(length(gold), k), &weight/1)
  end

  # Upstream's DCG weights ranks 1 and 2 equally: 1, then 1 / log2(rank).
  defp weight(1), do: 1.0
  defp weight(rank), do: 1 / :math.log2(rank)

  defp memory_text(reasoned) do
    [episodic: reasoned.episodic, semantic: reasoned.semantic, procedural: reasoned.procedural]
    |> Enum.reject(fn {_type, summary} -> summary in [nil, ""] end)
    |> Enum.map_join("\n\n", fn {type, summary} -> "#{type} memory:\n#{summary}" end)
  end

  defp reader_prompt(memory, question) do
    "#{@reader}\n\n\nHistory Chats:\n\n#{memory}\n\n" <>
      "Current Date: #{question["question_date"]}\nQuestion: #{question["question"]}\nAnswer:"
  end

  defp judge_prompt(question, hypothesis) do
    abstention = String.ends_with?(question["question_id"], "_abs")
    {instructions, answer_label, ask} = rubric(question["question_type"], abstention)

    "#{instructions}\n\nQuestion: #{question["question"]}\n\n" <>
      "#{answer_label}: #{question["answer"]}\n\nModel Response: #{hypothesis}\n\n" <>
      "#{ask} Answer yes or no only."
  end

  defp rubric(_type, true) do
    {"I will give you an unanswerable question, an explanation, and a response from a model. " <>
       "Please answer yes if the model correctly identifies the question as unanswerable. " <>
       "The model could say that the information is incomplete, or some other information is " <>
       "given but the asked information is not.", "Explanation",
     "Does the model correctly identify the question as unanswerable?"}
  end

  defp rubric("temporal-reasoning", false) do
    {@equivalent <>
       "In addition, do not penalize off-by-one errors for the number of days. If the question " <>
       "asks for the number of days/weeks/months, etc., and the model makes off-by-one errors " <>
       "(e.g., predicting 19 days when the answer is 18), the model's response is still correct. ",
     "Correct Answer", @is_correct}
  end

  defp rubric("knowledge-update", false) do
    {@contains <>
       "If the response contains some previous information along with an updated answer, the " <>
       "response should be considered as correct as long as the updated answer is the required " <>
       "answer.", "Correct Answer", @is_correct}
  end

  defp rubric("single-session-preference", false) do
    {"I will give you a question, a rubric for desired personalized response, and a response " <>
       "from a model. Please answer yes if the response satisfies the desired response. " <>
       "Otherwise, answer no. The model does not need to reflect all the points in the rubric. " <>
       "The response is correct as long as it recalls and utilizes the user's personal " <>
       "information correctly.", "Rubric", @is_correct}
  end

  defp rubric(type, false)
       when type in ["single-session-user", "single-session-assistant", "multi-session"],
       do: {@equivalent, "Correct Answer", @is_correct}

  defp chat(model, prompt, opts) do
    messages = [%{role: :user, content: prompt}]

    with {:ok, response} <- SycophantLLM.chat(messages, [model: model, temperature: 0.0] ++ opts) do
      {:ok, String.trim(response.content || "")}
    end
  end

  defp summarize(rows) do
    scored = Enum.filter(rows, & &1["retrieval"])

    retrieval =
      case scored do
        [] ->
          %{}

        [first | _] ->
          Map.new(first["retrieval"], fn {name, _value} ->
            {name, mean(scored, & &1["retrieval"][name])}
          end)
      end

    %{
      "n" => length(rows),
      "accuracy" => mean(rows, &if(&1["correct"], do: 1, else: 0)),
      "memory_tokens" => mean(rows, & &1["memory_tokens"]),
      "retrieval_n" => length(scored),
      "retrieval" => retrieval
    }
  end

  defp mean([], _fun), do: nil
  defp mean(rows, fun), do: Float.round(Enum.sum_by(rows, fun) / length(rows), 4)

  defp print(summary) do
    columns = ["recall_any@5", "recall_all@5", "ndcg@10", "reader_recall"]
    header = ["group", "n", "accuracy", "mem_tokens" | columns]

    groups =
      [{"overall", summary["overall"]}, {"abstention", summary["abstention"]}] ++
        Enum.sort(summary["by_type"])

    lines =
      for {name, group} <- groups do
        [name, group["n"], group["accuracy"], group["memory_tokens"]] ++
          Enum.map(columns, &group["retrieval"][&1])
      end

    IO.puts("")

    for [name | cells] <- [header | lines] do
      IO.puts(String.pad_trailing(name, 28) <> Enum.map_join(cells, &pad/1))
    end

    IO.puts("\nusage this invocation:")

    for {model, usage} <- summary["usage_this_invocation"] do
      IO.puts(
        "#{String.pad_trailing(model, 44)} calls=#{usage.calls} in=#{usage.input_tokens} " <>
          "out=#{usage.output_tokens} cost=$#{Float.round(usage.cost / 1, 4)}"
      )
    end

    :ok
  end

  defp pad(nil), do: pad("-")
  defp pad(cell), do: cell |> to_string() |> String.pad_leading(14)
end

LongMemEval.main(System.argv())
