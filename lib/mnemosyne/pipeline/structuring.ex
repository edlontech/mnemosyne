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
    Mnemosyne.Telemetry.span([:structuring, :extract], %{episode_id: episode.id}, fn ->
      llm = Keyword.fetch!(opts, :llm)
      embedding = Keyword.fetch!(opts, :embedding)
      llm_opts = Keyword.get(opts, :llm_opts, [])
      config = Keyword.get(opts, :config)

      changesets =
        episode.trajectories
        |> Enum.map(fn trajectory ->
          Logger.debug("extracting trajectory #{trajectory.id}")

          extract_trajectory(episode, trajectory, llm, embedding, llm_opts, config)
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
    end)
  end

  defp extract_trajectory(episode, trajectory, llm, embedding, llm_opts, config) do
    extraction_tasks = [
      Task.async(fn ->
        extract_semantic(trajectory, episode.goal, llm, embedding, llm_opts, config)
      end),
      Task.async(fn ->
        extract_procedural(trajectory, episode.goal, llm, embedding, llm_opts, config)
      end),
      Task.async(fn -> compute_return(trajectory, episode.goal, llm, llm_opts, config) end)
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
      base_cs = build_base_changeset(episode, trajectory, return_value)

      {:ok,
       base_cs
       |> Changeset.merge(semantic_cs)
       |> Changeset.merge(procedural_cs)}
    end
  end

  defp build_base_changeset(episode, trajectory, _return_value) do
    subgoal_node = %Subgoal{
      id: generate_id("sg"),
      description: trajectory.subgoal,
      parent_goal: episode.goal
    }

    cs = Changeset.add_node(Changeset.new(), subgoal_node)

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
        episode_id: episode.id,
        step_index: step.index
      }

      acc
      |> Changeset.add_node(episodic_node)
      |> Changeset.add_node(source_node)
      |> Changeset.add_link(episodic_id, subgoal_node.id)
      |> Changeset.add_link(episodic_id, source_id)
    end)
  end

  defp extract_semantic(trajectory, goal, llm, embedding, llm_opts, config) do
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

      cs =
        facts
        |> Enum.zip(prop_embeddings)
        |> Enum.reduce(Changeset.new(), &add_semantic_node(&1, &2, concept_map))

      cs = Enum.reduce(Map.values(concept_map), cs, &Changeset.add_node(&2, &1))

      {:ok, cs}
    end
  end

  defp add_semantic_node({fact, emb}, cs, concept_map) do
    sem_node = %Semantic{
      id: generate_id("sem"),
      proposition: fact.proposition,
      confidence: 1.0,
      embedding: emb
    }

    cs = Changeset.add_node(cs, sem_node)

    Enum.reduce(fact.concepts, cs, fn concept_label, acc ->
      case Map.fetch(concept_map, concept_label) do
        {:ok, tag} -> Changeset.add_link(acc, tag.id, sem_node.id)
        :error -> acc
      end
    end)
  end

  defp extract_procedural(trajectory, goal, llm, embedding, llm_opts, config) do
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

      cs =
        instructions
        |> Enum.zip(proc_embeddings)
        |> Enum.reduce(Changeset.new(), &add_procedural_node(&1, &2, intent_map))

      cs = Enum.reduce(Map.values(intent_map), cs, &Changeset.add_node(&2, &1))

      {:ok, cs}
    end
  end

  defp add_procedural_node({instr, emb}, cs, intent_map) do
    proc_node = %Procedural{
      id: generate_id("proc"),
      instruction: instr.instruction,
      condition: instr.condition,
      expected_outcome: instr.expected_outcome,
      embedding: emb
    }

    cs = Changeset.add_node(cs, proc_node)

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

  defp generate_id(prefix) do
    "#{prefix}_#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"
  end
end
