defmodule Mnemosyne.Pipeline.Structuring do
  @moduledoc """
  Orchestrates knowledge extraction from a closed episode.

  For each trajectory segment, runs GetSemantic, GetProcedural,
  and GetReturn in parallel to extract knowledge nodes, then
  assembles a Graph.Changeset with all nodes and links.
  """

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Episodic
  alias Mnemosyne.Graph.Node.Procedural
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Source
  alias Mnemosyne.Graph.Node.Subgoal
  alias Mnemosyne.Pipeline.Episode
  alias Mnemosyne.Pipeline.Prompts.GetProcedural, as: ProceduralPrompt
  alias Mnemosyne.Pipeline.Prompts.GetReturn
  alias Mnemosyne.Pipeline.Prompts.GetSemantic, as: SemanticPrompt

  @doc "Extracts knowledge nodes from a closed episode into a changeset."
  @spec extract(Episode.t(), keyword()) :: {:ok, Changeset.t()} | {:error, term()}
  def extract(%Episode{closed: false}, _opts), do: {:error, :episode_not_closed}

  def extract(%Episode{} = episode, opts) do
    llm = Keyword.fetch!(opts, :llm)
    embedding = Keyword.fetch!(opts, :embedding)
    llm_opts = Keyword.get(opts, :llm_opts, [])
    config = Keyword.get(opts, :config)

    changesets =
      episode.trajectories
      |> Enum.map(&extract_trajectory(episode, &1, llm, embedding, llm_opts, config))
      |> collect_results()

    case changesets do
      {:ok, css} -> {:ok, Enum.reduce(css, Changeset.new(), &Changeset.merge(&2, &1))}
      {:error, _} = err -> err
    end
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
      Task.await_many(extraction_tasks, :timer.seconds(60))

    with {:ok, semantic_cs} <- semantic_result,
         {:ok, procedural_cs} <- procedural_result,
         {:ok, return_value} <- return_result do
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
           llm.chat(messages, Config.llm_opts(config, :get_semantic, llm_opts)),
         {:ok, facts} <- SemanticPrompt.parse_response(content),
         {:ok, %Embedding.Response{vectors: embeddings}} <-
           embedding.embed_batch(facts, Config.embedding_opts(config)) do
      cs =
        Enum.zip(facts, embeddings)
        |> Enum.reduce(Changeset.new(), fn {fact, emb}, acc ->
          node = %Semantic{
            id: generate_id("sem"),
            proposition: fact,
            confidence: 1.0,
            embedding: emb
          }

          Changeset.add_node(acc, node)
        end)

      {:ok, cs}
    end
  end

  defp extract_procedural(trajectory, goal, llm, embedding, llm_opts, config) do
    messages = ProceduralPrompt.build_messages(%{trajectory: trajectory.steps, goal: goal})

    with {:ok, %{content: content}} <-
           llm.chat(messages, Config.llm_opts(config, :get_procedural, llm_opts)),
         {:ok, instructions} <- ProceduralPrompt.parse_response(content),
         {:ok, %Embedding.Response{vectors: embeddings}} <-
           embedding.embed_batch(
             Enum.map(instructions, & &1.instruction),
             Config.embedding_opts(config)
           ) do
      cs =
        Enum.zip(instructions, embeddings)
        |> Enum.reduce(Changeset.new(), fn {instr, emb}, acc ->
          node = %Procedural{
            id: generate_id("proc"),
            instruction: instr.instruction,
            condition: instr.condition,
            expected_outcome: instr.expected_outcome,
            embedding: emb
          }

          Changeset.add_node(acc, node)
        end)

      {:ok, cs}
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

  defp generate_id(prefix) do
    "#{prefix}_#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"
  end
end
