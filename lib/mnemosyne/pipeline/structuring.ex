defmodule Mnemosyne.Pipeline.Structuring do
  @moduledoc """
  Orchestrates knowledge extraction from a closed episode.

  For each trajectory segment, runs GetSemantic, GetProcedural,
  and GetReturn in parallel to extract knowledge nodes, then
  assembles a Graph.Changeset with all nodes and links.
  """

  require Logger

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.Errors.Invalid.EpisodeError
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Episodic
  alias Mnemosyne.Graph.Node.Intent
  alias Mnemosyne.Graph.Node.Procedural
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Source
  alias Mnemosyne.Graph.Node.Subgoal
  alias Mnemosyne.Graph.Node.Tag
  alias Mnemosyne.NodeMetadata
  alias Mnemosyne.Notifier.Trace.Structuring, as: StructuringTrace
  alias Mnemosyne.Pipeline.Episode
  alias Mnemosyne.Pipeline.Prompts.GetProcedural, as: ProceduralPrompt
  alias Mnemosyne.Pipeline.Prompts.GetReturn
  alias Mnemosyne.Pipeline.Prompts.GetSemantic, as: SemanticPrompt
  alias Mnemosyne.Pipeline.Prompts.GetState

  @doc "Extracts knowledge nodes from a closed episode into a changeset."
  @spec extract(Episode.t(), keyword()) ::
          {:ok, Changeset.t()} | {:error, Mnemosyne.Errors.error()}
  def extract(%Episode{closed: false}, _opts),
    do: {:error, EpisodeError.exception(reason: :episode_not_closed)}

  def extract(%Episode{} = episode, opts) do
    Mnemosyne.Telemetry.span(
      [:structuring, :extract],
      %{
        episode_id: episode.id,
        repo_id: Keyword.get(opts, :repo_id),
        session_id: Keyword.get(opts, :session_id)
      },
      fn ->
        changesets =
          episode.trajectories
          |> Enum.map(fn trajectory ->
            Logger.debug("extracting trajectory #{trajectory.id}")

            extract_trajectory(
              trajectory,
              episode.goal,
              Keyword.put(opts, :episode_id, episode.id)
            )
          end)
          |> collect_results()

        case changesets do
          {:ok, css} ->
            cs = Enum.reduce(css, Changeset.new(), &Changeset.merge(&2, &1))

            {{:ok, cs},
             %{
               trajectory_count: length(episode.trajectories),
               nodes_created: length(cs.additions),
               links_created: length(cs.links)
             }}

          {:error, _} = err ->
            {err, %{}}
        end
      end
    )
  end

  @doc "Extracts knowledge nodes from a single trajectory into a changeset."
  @spec extract_trajectory(Episode.trajectory(), String.t(), keyword()) ::
          {:ok, Changeset.t()} | {:error, Mnemosyne.Errors.error()}
  def extract_trajectory(trajectory, goal, opts) do
    llm = Keyword.fetch!(opts, :llm)
    embedding = Keyword.fetch!(opts, :embedding)
    llm_opts = Keyword.get(opts, :llm_opts, [])
    config = Keyword.get(opts, :config)

    Mnemosyne.Telemetry.span(
      [:structuring, :extract_trajectory],
      %{
        trajectory_id: trajectory.id,
        repo_id: Keyword.get(opts, :repo_id),
        session_id: Keyword.get(opts, :session_id)
      },
      fn ->
        episode_id = Keyword.get_lazy(opts, :episode_id, fn -> generate_id("ep") end)

        case do_extract_trajectory(trajectory, goal, episode_id, llm, embedding, llm_opts, config) do
          {:ok, cs, trace} ->
            {{:ok, cs, trace},
             %{nodes_created: length(cs.additions), links_created: length(cs.links)}}

          {:error, _} = err ->
            {err, %{}}
        end
      end
    )
  end

  defp do_extract_trajectory(trajectory, goal, episode_id, llm, embedding, llm_opts, config) do
    start_time = System.monotonic_time(:microsecond)

    with {:ok, trajectory} <- derive_progressive_states(trajectory, llm, llm_opts, config) do
      do_extract_trajectory_inner(
        trajectory,
        goal,
        episode_id,
        llm,
        embedding,
        llm_opts,
        config,
        start_time
      )
    end
  end

  defp do_extract_trajectory_inner(
         trajectory,
         goal,
         episode_id,
         llm,
         embedding,
         llm_opts,
         config,
         start_time
       ) do
    avg_reward = trajectory_avg_reward(trajectory)
    episodic_ids = Enum.map(trajectory.steps, fn _step -> generate_id("ep_node") end)

    extraction_tasks = [
      Task.async(fn ->
        extract_semantic(
          trajectory,
          goal,
          llm,
          embedding,
          llm_opts,
          config,
          avg_reward,
          episodic_ids
        )
      end),
      Task.async(fn ->
        extract_procedural(
          trajectory,
          goal,
          llm,
          embedding,
          llm_opts,
          config,
          avg_reward,
          episodic_ids
        )
      end)
    ]

    [semantic_result, procedural_result] =
      try do
        Task.await_many(extraction_tasks, :timer.seconds(60))
      rescue
        e ->
          Logger.warning("extraction tasks timed out after 60s for trajectory #{trajectory.id}")

          reraise e, __STACKTRACE__
      end

    with {:ok, semantic_cs} <- tag_result(semantic_result, :semantic),
         {:ok, procedural_cs, instructions} <- tag_procedural_result(procedural_result),
         {:ok, scores} <- compute_return(trajectory, goal, instructions, llm, llm_opts, config) do
      procedural_cs = stamp_return_scores(procedural_cs, scores)
      base_cs = build_base_changeset(goal, episode_id, trajectory, episodic_ids)

      cs =
        base_cs
        |> Changeset.merge(semantic_cs)
        |> Changeset.merge(procedural_cs)

      duration_us = System.monotonic_time(:microsecond) - start_time
      verbosity = if config, do: config.trace_verbosity, else: :summary

      trace = %StructuringTrace{
        verbosity: verbosity,
        trajectory_id: trajectory.id,
        semantic_count: count_nodes_of_type(cs, Semantic),
        procedural_count: count_nodes_of_type(cs, Procedural),
        tag_count: count_nodes_of_type(cs, Tag),
        intent_count: count_nodes_of_type(cs, Intent),
        duration_us: duration_us
      }

      {:ok, cs, trace}
    end
  end

  defp derive_progressive_states(trajectory, llm, llm_opts, config) do
    trajectory.steps
    |> Enum.reduce_while({:ok, []}, fn step, {:ok, acc} ->
      previous_state =
        case acc do
          [] -> nil
          [prev | _] -> prev.state
        end

      messages =
        GetState.build_messages(%{
          previous_state: previous_state,
          action: step.action,
          observation: step.observation,
          goal: trajectory.subgoal
        })

      with {:ok, %{content: content}} <-
             llm.chat(messages, Config.llm_opts(config, :get_state, llm_opts)),
           {:ok, state} <- GetState.parse_response(content) do
        {:cont, {:ok, [%{step | state: state} | acc]}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, reversed_steps} ->
        {:ok, %{trajectory | steps: Enum.reverse(reversed_steps)}}

      {:error, _} = err ->
        err
    end
  end

  defp trajectory_avg_reward(%{steps: []}), do: 0.0

  defp trajectory_avg_reward(%{steps: steps}) do
    total = Enum.reduce(steps, 0.0, fn step, acc -> acc + (step.reward || 0.0) end)
    total / length(steps)
  end

  defp build_base_changeset(goal, episode_id, trajectory, episodic_ids) do
    subgoal_node = %Subgoal{
      id: generate_id("sg"),
      description: trajectory.subgoal,
      parent_goal: goal
    }

    cs =
      Changeset.new()
      |> Changeset.add_node(subgoal_node)
      |> Changeset.put_metadata(subgoal_node.id, NodeMetadata.new())

    trajectory.steps
    |> Enum.zip(episodic_ids)
    |> Enum.reduce(cs, fn {step, episodic_id}, acc ->
      source_id = generate_id("src")

      episodic_node = %Episodic{
        id: episodic_id,
        observation: step.observation,
        action: step.action,
        state: step.state,
        subgoal: step.subgoal,
        reward: step.reward,
        trajectory_id: trajectory.id,
        embedding: step.embedding
      }

      source_node = %Source{
        id: source_id,
        episode_id: episode_id,
        step_index: step.index
      }

      acc
      |> Changeset.add_node(episodic_node)
      |> Changeset.add_node(source_node)
      |> Changeset.put_metadata(episodic_id, NodeMetadata.new())
      |> Changeset.put_metadata(source_id, NodeMetadata.new())
      |> Changeset.add_link(episodic_id, subgoal_node.id)
      |> Changeset.add_link(episodic_id, source_id)
    end)
  end

  defp extract_semantic(
         trajectory,
         goal,
         llm,
         embedding,
         llm_opts,
         config,
         avg_reward,
         episodic_ids
       ) do
    messages = SemanticPrompt.build_messages(%{trajectory: trajectory.steps, goal: goal})

    with {:ok, %{content: content}} <-
           llm.chat_structured(
             messages,
             SemanticPrompt.schema(),
             Config.llm_opts(config, :get_semantic, llm_opts)
           ),
         {:ok, facts} <- SemanticPrompt.parse_response(content),
         {:ok, %Embedding.Response{vectors: prop_embeddings}} <-
           embedding.embed_batch(Enum.map(facts, & &1.proposition), Config.embedding_opts(config)) do
      all_concepts = facts |> Enum.flat_map(& &1.concepts) |> Enum.uniq()
      concept_map = build_concept_map(all_concepts, embedding, config)

      reward_meta = NodeMetadata.new(cumulative_reward: avg_reward, reward_count: 1)

      {cs, sem_ids} =
        facts
        |> Enum.zip(prop_embeddings)
        |> Enum.reduce({Changeset.new(), []}, fn fact_emb, {acc_cs, acc_ids} ->
          {node, updated_cs} = add_semantic_node(fact_emb, acc_cs, concept_map, reward_meta)
          {updated_cs, [node.id | acc_ids]}
        end)

      cs =
        cs
        |> add_sibling_links(sem_ids)
        |> add_provenance_links(sem_ids, episodic_ids)

      cs =
        Enum.reduce(Map.values(concept_map), cs, fn tag, acc ->
          acc
          |> Changeset.add_node(tag)
          |> Changeset.put_metadata(tag.id, NodeMetadata.new())
        end)

      {:ok, cs}
    end
  end

  defp add_semantic_node({fact, emb}, cs, concept_map, reward_meta) do
    sem_node = %Semantic{
      id: generate_id("sem"),
      proposition: fact.proposition,
      confidence: fact.confidence,
      embedding: emb
    }

    cs =
      cs
      |> Changeset.add_node(sem_node)
      |> Changeset.put_metadata(sem_node.id, reward_meta)

    cs =
      Enum.reduce(fact.concepts, cs, fn concept_label, acc ->
        case Map.fetch(concept_map, concept_label) do
          {:ok, tag} -> Changeset.add_link(acc, tag.id, sem_node.id)
          :error -> acc
        end
      end)

    {sem_node, cs}
  end

  defp extract_procedural(
         trajectory,
         goal,
         llm,
         embedding,
         llm_opts,
         config,
         avg_reward,
         episodic_ids
       ) do
    messages = ProceduralPrompt.build_messages(%{trajectory: trajectory.steps, goal: goal})

    with {:ok, %{content: content}} <-
           llm.chat_structured(
             messages,
             ProceduralPrompt.schema(),
             Config.llm_opts(config, :get_procedural, llm_opts)
           ),
         {:ok, instructions} <- ProceduralPrompt.parse_response(content),
         {:ok, %Embedding.Response{vectors: proc_embeddings}} <-
           embedding.embed_batch(
             Enum.map(instructions, & &1.instruction),
             Config.embedding_opts(config)
           ) do
      all_intents = instructions |> Enum.map(& &1.intent) |> Enum.uniq()
      intent_map = build_intent_map(all_intents, embedding, config)

      reward_meta = NodeMetadata.new(cumulative_reward: avg_reward, reward_count: 1)

      {cs, proc_ids} =
        instructions
        |> Enum.zip(proc_embeddings)
        |> Enum.reduce({Changeset.new(), []}, fn instr_emb, {acc_cs, acc_ids} ->
          {node, updated_cs} = add_procedural_node(instr_emb, acc_cs, intent_map, reward_meta)
          {updated_cs, [node.id | acc_ids]}
        end)

      cs = add_provenance_links(cs, proc_ids, episodic_ids)

      cs =
        Enum.reduce(Map.values(intent_map), cs, fn intent, acc ->
          acc
          |> Changeset.add_node(intent)
          |> Changeset.put_metadata(intent.id, NodeMetadata.new())
        end)

      {:ok, cs, instructions}
    end
  end

  defp add_procedural_node({instr, emb}, cs, intent_map, reward_meta) do
    proc_node = %Procedural{
      id: generate_id("proc"),
      instruction: instr.instruction,
      condition: instr.condition,
      expected_outcome: instr.expected_outcome,
      embedding: emb
    }

    cs =
      cs
      |> Changeset.add_node(proc_node)
      |> Changeset.put_metadata(proc_node.id, reward_meta)

    cs =
      case Map.fetch(intent_map, instr.intent) do
        {:ok, intent} -> Changeset.add_link(cs, intent.id, proc_node.id)
        :error -> cs
      end

    {proc_node, cs}
  end

  defp compute_return(_trajectory, _goal, [], _llm, _llm_opts, _config), do: {:ok, []}

  defp compute_return(trajectory, goal, instructions, llm, llm_opts, config) do
    prescriptions =
      instructions
      |> Enum.with_index()
      |> Enum.map(fn {instr, idx} ->
        %{
          index: idx,
          instruction: instr.instruction,
          condition: instr.condition,
          expected_outcome: instr.expected_outcome
        }
      end)

    messages =
      GetReturn.build_messages(%{
        trajectory: trajectory.steps,
        goal: goal,
        prescriptions: prescriptions
      })

    with {:ok, %{content: content}} <-
           llm.chat_structured(
             messages,
             GetReturn.schema(),
             Config.llm_opts(config, :get_return, llm_opts)
           ) do
      GetReturn.parse_response(content)
    end
  end

  defp tag_procedural_result({:ok, cs, instructions}), do: {:ok, cs, instructions}

  defp tag_procedural_result({:error, reason} = err) do
    Logger.error("procedural extraction failed: #{inspect(reason)}")
    err
  end

  defp stamp_return_scores(cs, scores) do
    score_map = Map.new(scores, fn %{index: idx, return_score: score} -> {idx, score} end)

    proc_nodes = Enum.filter(cs.additions, &is_struct(&1, Procedural))

    proc_nodes
    |> Enum.with_index()
    |> Enum.reduce(cs, fn {node, idx}, acc ->
      case Map.fetch(score_map, idx) do
        {:ok, score} ->
          updated_node = %{node | return_score: score}

          acc
          |> update_node_in_additions(node, updated_node)
          |> Changeset.put_metadata(
            node.id,
            NodeMetadata.new(cumulative_reward: score, reward_count: 1)
          )

        :error ->
          acc
      end
    end)
  end

  defp update_node_in_additions(cs, old_node, new_node) do
    updated_additions =
      Enum.map(cs.additions, fn
        n when n == old_node -> new_node
        n -> n
      end)

    %{cs | additions: updated_additions}
  end

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, cs, _trace}, {:ok, acc} -> {:cont, {:ok, [cs | acc]}}
      {:error, _} = err, _acc -> {:halt, err}
    end)
    |> case do
      {:ok, css} -> {:ok, Enum.reverse(css)}
      err -> err
    end
  end

  defp tag_result({:ok, _} = ok, _step), do: ok

  defp tag_result({:error, reason} = err, step) do
    Logger.error("#{step} extraction failed: #{inspect(reason)}")
    err
  end

  defp build_concept_map([], _embedding, _config), do: %{}

  defp build_concept_map(concepts, embedding, config) do
    case embedding.embed_batch(concepts, Config.embedding_opts(config)) do
      {:ok, %Embedding.Response{vectors: embeddings}} ->
        Enum.zip(concepts, embeddings)
        |> Map.new(fn {label, emb} ->
          id = generate_id("tag")
          {label, %Tag{id: id, label: label, embedding: emb}}
        end)

      _ ->
        %{}
    end
  end

  defp build_intent_map([], _embedding, _config), do: %{}

  defp build_intent_map(intents, embedding, config) do
    case embedding.embed_batch(intents, Config.embedding_opts(config)) do
      {:ok, %Embedding.Response{vectors: embeddings}} ->
        Enum.zip(intents, embeddings)
        |> Map.new(fn {desc, emb} ->
          id = generate_id("int")
          {desc, %Intent{id: id, description: desc, embedding: emb}}
        end)

      _ ->
        %{}
    end
  end

  defp add_provenance_links(cs, knowledge_ids, episodic_ids) do
    for k_id <- knowledge_ids, e_id <- episodic_ids, reduce: cs do
      acc -> Changeset.add_link(acc, k_id, e_id)
    end
  end

  defp add_sibling_links(cs, ids) do
    ids
    |> pairs()
    |> Enum.reduce(cs, fn {a, b}, acc -> Changeset.add_link(acc, a, b) end)
  end

  defp pairs([]), do: []
  defp pairs([_]), do: []
  defp pairs([h | t]), do: Enum.map(t, &{h, &1}) ++ pairs(t)

  defp count_nodes_of_type(cs, mod) do
    Enum.count(cs.additions, &is_struct(&1, mod))
  end

  defp generate_id(prefix) do
    "#{prefix}_#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"
  end
end
