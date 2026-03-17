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
  alias Mnemosyne.Pipeline.Episode
  alias Mnemosyne.Pipeline.Prompts.GetProcedural, as: ProceduralPrompt
  alias Mnemosyne.Pipeline.Prompts.GetReturn
  alias Mnemosyne.Pipeline.Prompts.GetSemantic, as: SemanticPrompt

  @doc "Extracts knowledge nodes from a closed episode into a changeset."
  @spec extract(Episode.t(), keyword()) ::
          {:ok, Changeset.t()} | {:error, Mnemosyne.Errors.error()}
  def extract(%Episode{closed: false}, _opts),
    do: {:error, EpisodeError.exception(reason: :episode_not_closed)}

  def extract(%Episode{} = episode, opts) do
    Mnemosyne.Telemetry.span(
      [:structuring, :extract],
      %{episode_id: episode.id, repo_id: Keyword.get(opts, :repo_id)},
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
      %{trajectory_id: trajectory.id, repo_id: Keyword.get(opts, :repo_id)},
      fn ->
        episode_id = Keyword.get_lazy(opts, :episode_id, fn -> generate_id("ep") end)

        case do_extract_trajectory(trajectory, goal, episode_id, llm, embedding, llm_opts, config) do
          {:ok, cs} ->
            {{:ok, cs}, %{nodes_created: length(cs.additions), links_created: length(cs.links)}}

          {:error, _} = err ->
            {err, %{}}
        end
      end
    )
  end

  defp do_extract_trajectory(trajectory, goal, episode_id, llm, embedding, llm_opts, config) do
    avg_reward = trajectory_avg_reward(trajectory)

    extraction_tasks = [
      Task.async(fn ->
        extract_semantic(trajectory, goal, llm, embedding, llm_opts, config, avg_reward)
      end),
      Task.async(fn ->
        extract_procedural(trajectory, goal, llm, embedding, llm_opts, config, avg_reward)
      end),
      Task.async(fn -> compute_return(trajectory, goal, llm, llm_opts, config) end)
    ]

    [semantic_result, procedural_result, return_result] =
      try do
        Task.await_many(extraction_tasks, :timer.seconds(60))
      rescue
        e ->
          Logger.warning("extraction tasks timed out after 60s for trajectory #{trajectory.id}")

          reraise e, __STACKTRACE__
      end

    with {:ok, semantic_cs} <- tag_result(semantic_result, :semantic),
         {:ok, procedural_cs} <- tag_result(procedural_result, :procedural),
         {:ok, return_value} <- tag_result(return_result, :return) do
      base_cs = build_base_changeset(goal, episode_id, trajectory, return_value)

      {:ok,
       base_cs
       |> Changeset.merge(semantic_cs)
       |> Changeset.merge(procedural_cs)}
    end
  end

  defp trajectory_avg_reward(%{steps: []}), do: 0.0

  defp trajectory_avg_reward(%{steps: steps}) do
    total = Enum.reduce(steps, 0.0, fn step, acc -> acc + (step.reward || 0.0) end)
    total / length(steps)
  end

  defp build_base_changeset(goal, episode_id, trajectory, _return_value) do
    subgoal_node = %Subgoal{
      id: generate_id("sg"),
      description: trajectory.subgoal,
      parent_goal: goal
    }

    cs =
      Changeset.new()
      |> Changeset.add_node(subgoal_node)
      |> Changeset.put_metadata(subgoal_node.id, NodeMetadata.new())

    Enum.reduce(trajectory.steps, cs, fn step, acc ->
      episodic_id = generate_id("ep_node")
      source_id = generate_id("src")

      episodic_node = %Episodic{
        id: episodic_id,
        observation: step.observation,
        action: step.action,
        state: step.state,
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

  defp extract_semantic(trajectory, goal, llm, embedding, llm_opts, config, avg_reward) do
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

      cs = add_sibling_links(cs, sem_ids)

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
      confidence: 1.0,
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

  defp extract_procedural(trajectory, goal, llm, embedding, llm_opts, config, avg_reward) do
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

      cs =
        instructions
        |> Enum.zip(proc_embeddings)
        |> Enum.reduce(Changeset.new(), &add_procedural_node(&1, &2, intent_map, reward_meta))

      cs =
        Enum.reduce(Map.values(intent_map), cs, fn intent, acc ->
          acc
          |> Changeset.add_node(intent)
          |> Changeset.put_metadata(intent.id, NodeMetadata.new())
        end)

      {:ok, cs}
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

    case Map.fetch(intent_map, instr.intent) do
      {:ok, intent} -> Changeset.add_link(cs, intent.id, proc_node.id)
      :error -> cs
    end
  end

  defp compute_return(trajectory, goal, llm, llm_opts, config) do
    messages = GetReturn.build_messages(%{trajectory: trajectory.steps, goal: goal})

    with {:ok, %{content: content}} <-
           llm.chat(messages, Config.llm_opts(config, :get_return, llm_opts)) do
      GetReturn.parse_response(content)
    end
  end

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, cs}, {:ok, acc} -> {:cont, {:ok, [cs | acc]}}
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

  defp add_sibling_links(cs, ids) do
    ids
    |> pairs()
    |> Enum.reduce(cs, fn {a, b}, acc -> Changeset.add_link(acc, a, b) end)
  end

  defp pairs([]), do: []
  defp pairs([_]), do: []
  defp pairs([h | t]), do: Enum.map(t, &{h, &1}) ++ pairs(t)

  defp generate_id(prefix) do
    "#{prefix}_#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"
  end
end
