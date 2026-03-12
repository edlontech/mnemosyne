defmodule Mnemosyne.Pipeline.StructuringTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.LLM
  alias Mnemosyne.Pipeline.Episode
  alias Mnemosyne.Pipeline.Structuring

  @default_opts [llm: Mnemosyne.MockLLM, embedding: Mnemosyne.MockEmbedding]
  @test_config %Config{
    llm: %{model: "test:model", opts: %{}},
    embedding: %{model: "test:embed", opts: %{}},
    overrides: %{}
  }

  setup :set_mimic_global

  defp build_closed_episode do
    stub_append_cycle()
    episode = Episode.new("Optimize the database")
    {:ok, episode} = Episode.append(episode, "Slow query found", "Added index", @default_opts)

    stub_append_cycle("Continue optimization", "0.9")
    {:ok, episode} = Episode.append(episode, "Index applied", "Run benchmark", @default_opts)

    {:ok, closed} = Episode.close(episode)
    closed
  end

  defp stub_append_cycle(subgoal \\ "Optimize queries", reward \\ "0.8") do
    stub_llm_responses([subgoal, reward, "Current state"])
    stub_default_embedding()
  end

  defp stub_llm_responses(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    Mnemosyne.MockLLM
    |> stub(:chat, fn _messages, _opts ->
      content =
        Agent.get_and_update(agent, fn
          [head | tail] -> {head, tail}
          [] -> {"default", []}
        end)

      {:ok, %LLM.Response{content: content, model: "mock:test", usage: %{}}}
    end)
  end

  defp stub_default_embedding do
    Mnemosyne.MockEmbedding
    |> stub(:embed, fn _text, _opts ->
      {:ok,
       %Embedding.Response{vectors: [List.duplicate(0.1, 128)], model: "mock:embed", usage: %{}}}
    end)
    |> stub(:embed_batch, fn texts, _opts ->
      vectors = Enum.map(texts, fn _ -> List.duplicate(0.1, 128) end)
      {:ok, %Embedding.Response{vectors: vectors, model: "mock:embed", usage: %{}}}
    end)
  end

  defp stub_extraction_llm do
    semantic_response = "Adding indexes improves query speed\nThe users table was the bottleneck"
    procedural_response = "WHEN: Query exceeds 1s\nDO: Add an index\nEXPECT: Sub-100ms response"
    return_response = "0.85"

    Mnemosyne.MockLLM
    |> stub(:chat, fn messages, _opts ->
      system_content =
        messages
        |> Enum.find(%{content: ""}, &(&1.role == :system))
        |> Map.get(:content)

      content =
        cond do
          system_content =~ "factual knowledge" -> semantic_response
          system_content =~ "actionable instructions" -> procedural_response
          system_content =~ "return value" -> return_response
          true -> "default"
        end

      {:ok, %LLM.Response{content: content, model: "mock:test", usage: %{}}}
    end)

    stub_default_embedding()
  end

  describe "extract/2" do
    test "rejects open episodes" do
      episode = Episode.new("test")

      assert {:error, :episode_not_closed} =
               Structuring.extract(episode, @default_opts)
    end

    test "extracts knowledge from closed episode into changeset" do
      episode = build_closed_episode()
      stub_extraction_llm()

      assert {:ok, %Changeset{} = cs} = Structuring.extract(episode, @default_opts)

      assert [_ | _] = cs.additions
      assert [_ | _] = cs.links

      types = Enum.map(cs.additions, &struct_type/1) |> Enum.uniq() |> Enum.sort()
      assert :episodic in types
      assert :source in types
      assert :subgoal in types
    end

    test "creates episodic nodes for each step" do
      episode = build_closed_episode()
      stub_extraction_llm()

      {:ok, cs} = Structuring.extract(episode, @default_opts)

      episodic_nodes = Enum.filter(cs.additions, &match?(%Mnemosyne.Graph.Node.Episodic{}, &1))
      assert length(episodic_nodes) == 2
    end

    test "creates source nodes linking back to episode" do
      episode = build_closed_episode()
      stub_extraction_llm()

      {:ok, cs} = Structuring.extract(episode, @default_opts)

      source_nodes = Enum.filter(cs.additions, &match?(%Mnemosyne.Graph.Node.Source{}, &1))
      assert length(source_nodes) == 2
      assert Enum.all?(source_nodes, &(&1.episode_id == episode.id))
    end

    test "creates subgoal nodes for trajectories" do
      episode = build_closed_episode()
      stub_extraction_llm()

      {:ok, cs} = Structuring.extract(episode, @default_opts)

      subgoal_nodes = Enum.filter(cs.additions, &match?(%Mnemosyne.Graph.Node.Subgoal{}, &1))
      assert [_ | _] = subgoal_nodes
      assert Enum.all?(subgoal_nodes, &(&1.parent_goal == "Optimize the database"))
    end

    test "accepts config option and resolves per-step opts" do
      episode = build_closed_episode()

      Mnemosyne.MockLLM
      |> stub(:chat, fn messages, opts ->
        assert Keyword.get(opts, :model) == "test:model"

        system_content =
          messages
          |> Enum.find(%{content: ""}, &(&1.role == :system))
          |> Map.get(:content)

        content =
          cond do
            system_content =~ "factual knowledge" ->
              "Adding indexes improves query speed\nThe users table was the bottleneck"

            system_content =~ "actionable instructions" ->
              "WHEN: Query exceeds 1s\nDO: Add an index\nEXPECT: Sub-100ms response"

            system_content =~ "return value" ->
              "0.85"

            true ->
              "default"
          end

        {:ok, %LLM.Response{content: content, model: "mock:test", usage: %{}}}
      end)

      stub_default_embedding()

      opts = @default_opts ++ [config: @test_config]

      assert {:ok, %Changeset{} = cs} = Structuring.extract(episode, opts)

      assert [_ | _] = cs.additions
      assert [_ | _] = cs.links
    end

    test "propagates LLM errors during extraction" do
      episode = build_closed_episode()

      Mnemosyne.MockLLM
      |> stub(:chat, fn _messages, _opts -> {:error, :extraction_failed} end)

      stub_default_embedding()

      assert {:error, :extraction_failed} = Structuring.extract(episode, @default_opts)
    end
  end

  defp struct_type(%Mnemosyne.Graph.Node.Episodic{}), do: :episodic
  defp struct_type(%Mnemosyne.Graph.Node.Semantic{}), do: :semantic
  defp struct_type(%Mnemosyne.Graph.Node.Procedural{}), do: :procedural
  defp struct_type(%Mnemosyne.Graph.Node.Source{}), do: :source
  defp struct_type(%Mnemosyne.Graph.Node.Subgoal{}), do: :subgoal
  defp struct_type(%Mnemosyne.Graph.Node.Tag{}), do: :tag
  defp struct_type(_), do: :unknown
end
