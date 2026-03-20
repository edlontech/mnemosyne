defmodule Mnemosyne.Pipeline.StructuringTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Mnemosyne.Config
  alias Mnemosyne.Embedding
  alias Mnemosyne.Errors.Invalid.EpisodeError
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.LLM
  alias Mnemosyne.NodeMetadata
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

    {:ok, episode, _trace} =
      Episode.append(episode, "Slow query found", "Added index", @default_opts)

    stub_append_cycle("Continue optimization", "0.9")

    {:ok, episode, _trace} =
      Episode.append(episode, "Index applied", "Run benchmark", @default_opts)

    {:ok, closed} = Episode.close(episode)
    closed
  end

  defp stub_append_cycle(subgoal \\ "Optimize queries", reward \\ "0.8") do
    stub_llm_responses([subgoal, reward])
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
    Mnemosyne.MockLLM
    |> stub(:chat, fn messages, _opts ->
      system_content =
        messages
        |> Enum.find(%{content: ""}, &(&1.role == :system))
        |> Map.get(:content)

      content =
        if system_content =~ "environment state" do
          "Derived state"
        else
          "default"
        end

      {:ok, %LLM.Response{content: content, model: "mock:test", usage: %{}}}
    end)
    |> stub(:chat_structured, fn messages, _schema, _opts ->
      system_content =
        messages
        |> Enum.find(%{content: ""}, &(&1.role == :system))
        |> Map.get(:content)

      content =
        cond do
          system_content =~ "factual knowledge" ->
            %{
              facts: [
                %{
                  proposition: "Adding indexes improves query speed",
                  concepts: ["indexes", "query speed"]
                },
                %{
                  proposition: "The users table was the bottleneck",
                  concepts: ["users table", "bottleneck"]
                }
              ]
            }

          system_content =~ "actionable instructions" ->
            %{
              instructions: [
                %{
                  intent: "Optimize slow database queries",
                  condition: "Query exceeds 1s",
                  instruction: "Add an index",
                  expected_outcome: "Sub-100ms response"
                }
              ]
            }

          system_content =~ "prescription quality" ->
            %{scores: [%{index: 0, return_score: 0.85}]}

          true ->
            %{}
        end

      {:ok, %LLM.Response{content: content, model: "mock:test", usage: %{}}}
    end)

    stub_default_embedding()
  end

  describe "extract/2" do
    test "rejects open episodes" do
      episode = Episode.new("test")

      assert {:error, %EpisodeError{reason: :episode_not_closed}} =
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
      assert :semantic in types
      assert :tag in types
      assert :intent in types
      assert :procedural in types
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
      |> stub(:chat_structured, fn messages, _schema, opts ->
        assert Keyword.get(opts, :model) == "test:model"

        system_content =
          messages
          |> Enum.find(%{content: ""}, &(&1.role == :system))
          |> Map.get(:content)

        content =
          cond do
            system_content =~ "factual knowledge" ->
              %{
                facts: [
                  %{
                    proposition: "Adding indexes improves query speed",
                    concepts: ["indexes", "query speed"]
                  },
                  %{
                    proposition: "The users table was the bottleneck",
                    concepts: ["users table", "bottleneck"]
                  }
                ]
              }

            system_content =~ "actionable instructions" ->
              %{
                instructions: [
                  %{
                    intent: "Optimize slow database queries",
                    condition: "Query exceeds 1s",
                    instruction: "Add an index",
                    expected_outcome: "Sub-100ms response"
                  }
                ]
              }

            system_content =~ "prescription quality" ->
              %{scores: [%{index: 0, return_score: 0.85}]}

            true ->
              %{}
          end

        {:ok, %LLM.Response{content: content, model: "mock:test", usage: %{}}}
      end)

      stub_default_embedding()

      opts = @default_opts ++ [config: @test_config]

      assert {:ok, %Changeset{} = cs} = Structuring.extract(episode, opts)

      assert [_ | _] = cs.additions
      assert [_ | _] = cs.links
    end

    test "creates tag nodes as concept indices linked to semantic nodes" do
      episode = build_closed_episode()
      stub_extraction_llm()

      {:ok, cs} = Structuring.extract(episode, @default_opts)

      tag_nodes = Enum.filter(cs.additions, &match?(%Mnemosyne.Graph.Node.Tag{}, &1))
      semantic_nodes = Enum.filter(cs.additions, &match?(%Mnemosyne.Graph.Node.Semantic{}, &1))

      assert tag_nodes != []
      assert semantic_nodes != []

      semantic_ids = MapSet.new(semantic_nodes, & &1.id)

      Enum.each(tag_nodes, fn tag ->
        assert tag.embedding != nil
        tag_links = Enum.filter(cs.links, fn {from, _to} -> from == tag.id end)
        assert tag_links != []

        Enum.each(tag_links, fn {_from, to} ->
          assert MapSet.member?(semantic_ids, to)
        end)
      end)
    end

    test "creates intent nodes linked to procedural nodes" do
      episode = build_closed_episode()
      stub_extraction_llm()

      {:ok, cs} = Structuring.extract(episode, @default_opts)

      intent_nodes = Enum.filter(cs.additions, &match?(%Mnemosyne.Graph.Node.Intent{}, &1))

      procedural_nodes =
        Enum.filter(cs.additions, &match?(%Mnemosyne.Graph.Node.Procedural{}, &1))

      assert intent_nodes != []
      assert procedural_nodes != []

      procedural_ids = MapSet.new(procedural_nodes, & &1.id)

      Enum.each(intent_nodes, fn intent ->
        assert intent.embedding != nil
        intent_links = Enum.filter(cs.links, fn {from, _to} -> from == intent.id end)
        assert intent_links != []

        Enum.each(intent_links, fn {_from, to} ->
          assert MapSet.member?(procedural_ids, to)
        end)
      end)
    end

    test "derives progressive states before extraction" do
      episode = build_closed_episode()
      stub_extraction_llm()

      {:ok, cs} = Structuring.extract(episode, @default_opts)

      episodic_nodes = Enum.filter(cs.additions, &match?(%Mnemosyne.Graph.Node.Episodic{}, &1))

      Enum.each(episodic_nodes, fn node ->
        assert node.state != nil
        assert is_binary(node.state)
      end)
    end

    test "propagates LLM errors during extraction" do
      episode = build_closed_episode()

      Mnemosyne.MockLLM
      |> stub(:chat, fn _messages, _opts -> {:error, :extraction_failed} end)

      Mnemosyne.MockLLM
      |> stub(:chat_structured, fn _messages, _schema, _opts -> {:error, :extraction_failed} end)

      stub_default_embedding()

      assert {:error, :extraction_failed} =
               Structuring.extract(episode, @default_opts)
    end

    test "changeset metadata contains entries for all created nodes" do
      episode = build_closed_episode()
      stub_extraction_llm()

      {:ok, cs} = Structuring.extract(episode, @default_opts)

      node_ids = Enum.map(cs.additions, &node_id/1)

      Enum.each(node_ids, fn id ->
        assert Map.has_key?(cs.metadata, id),
               "expected metadata for node #{id}"
      end)
    end

    test "semantic and procedural nodes have reward_count > 0" do
      episode = build_closed_episode()
      stub_extraction_llm()

      {:ok, cs} = Structuring.extract(episode, @default_opts)

      semantic_ids =
        cs.additions
        |> Enum.filter(&match?(%Mnemosyne.Graph.Node.Semantic{}, &1))
        |> Enum.map(& &1.id)

      procedural_ids =
        cs.additions
        |> Enum.filter(&match?(%Mnemosyne.Graph.Node.Procedural{}, &1))
        |> Enum.map(& &1.id)

      Enum.each(semantic_ids ++ procedural_ids, fn id ->
        meta = cs.metadata[id]
        assert %NodeMetadata{reward_count: rc} = meta
        assert rc > 0
      end)
    end

    test "adds pairwise sibling links between semantic nodes from same trajectory" do
      episode = build_closed_episode()
      stub_extraction_llm()

      {:ok, cs} = Structuring.extract(episode, @default_opts)

      semantic_ids =
        cs.additions
        |> Enum.filter(&match?(%Mnemosyne.Graph.Node.Semantic{}, &1))
        |> MapSet.new(& &1.id)

      sibling_links =
        Enum.filter(cs.links, fn {from, to} ->
          MapSet.member?(semantic_ids, from) and MapSet.member?(semantic_ids, to)
        end)

      # 2 semantic nodes => 2 choose 2 = 1 pair
      assert length(sibling_links) == 1
    end

    test "three semantic nodes produce three sibling links" do
      episode = build_closed_episode()

      Mnemosyne.MockLLM
      |> stub(:chat_structured, fn messages, _schema, _opts ->
        system_content =
          messages
          |> Enum.find(%{content: ""}, &(&1.role == :system))
          |> Map.get(:content)

        content =
          cond do
            system_content =~ "factual knowledge" ->
              %{
                facts: [
                  %{proposition: "Fact A", concepts: ["c1"]},
                  %{proposition: "Fact B", concepts: ["c1"]},
                  %{proposition: "Fact C", concepts: ["c2"]}
                ]
              }

            system_content =~ "actionable instructions" ->
              %{
                instructions: [
                  %{
                    intent: "Do something",
                    condition: "Always",
                    instruction: "Do it",
                    expected_outcome: "Done"
                  }
                ]
              }

            system_content =~ "prescription quality" ->
              %{scores: [%{index: 0, return_score: 0.75}]}

            true ->
              %{}
          end

        {:ok, %LLM.Response{content: content, model: "mock:test", usage: %{}}}
      end)

      stub_default_embedding()

      {:ok, cs} = Structuring.extract(episode, @default_opts)

      semantic_ids =
        cs.additions
        |> Enum.filter(&match?(%Mnemosyne.Graph.Node.Semantic{}, &1))
        |> MapSet.new(& &1.id)

      sibling_links =
        Enum.filter(cs.links, fn {from, to} ->
          MapSet.member?(semantic_ids, from) and MapSet.member?(semantic_ids, to)
        end)

      # 3 semantic nodes => 3 choose 2 = 3 pairs
      assert length(sibling_links) == 3
    end

    test "single semantic node produces no sibling links" do
      episode = build_closed_episode()

      Mnemosyne.MockLLM
      |> stub(:chat_structured, fn messages, _schema, _opts ->
        system_content =
          messages
          |> Enum.find(%{content: ""}, &(&1.role == :system))
          |> Map.get(:content)

        content =
          cond do
            system_content =~ "factual knowledge" ->
              %{facts: [%{proposition: "Only fact", concepts: ["c1"]}]}

            system_content =~ "actionable instructions" ->
              %{
                instructions: [
                  %{
                    intent: "Do something",
                    condition: "Always",
                    instruction: "Do it",
                    expected_outcome: "Done"
                  }
                ]
              }

            system_content =~ "prescription quality" ->
              %{scores: [%{index: 0, return_score: 0.75}]}

            true ->
              %{}
          end

        {:ok, %LLM.Response{content: content, model: "mock:test", usage: %{}}}
      end)

      stub_default_embedding()

      {:ok, cs} = Structuring.extract(episode, @default_opts)

      semantic_ids =
        cs.additions
        |> Enum.filter(&match?(%Mnemosyne.Graph.Node.Semantic{}, &1))
        |> MapSet.new(& &1.id)

      sibling_links =
        Enum.filter(cs.links, fn {from, to} ->
          MapSet.member?(semantic_ids, from) and MapSet.member?(semantic_ids, to)
        end)

      assert sibling_links == []
    end

    test "sibling links coexist with tag-to-semantic links" do
      episode = build_closed_episode()
      stub_extraction_llm()

      {:ok, cs} = Structuring.extract(episode, @default_opts)

      semantic_ids =
        cs.additions
        |> Enum.filter(&match?(%Mnemosyne.Graph.Node.Semantic{}, &1))
        |> MapSet.new(& &1.id)

      tag_ids =
        cs.additions
        |> Enum.filter(&match?(%Mnemosyne.Graph.Node.Tag{}, &1))
        |> MapSet.new(& &1.id)

      tag_to_sem_links =
        Enum.filter(cs.links, fn {from, to} ->
          MapSet.member?(tag_ids, from) and MapSet.member?(semantic_ids, to)
        end)

      sibling_links =
        Enum.filter(cs.links, fn {from, to} ->
          MapSet.member?(semantic_ids, from) and MapSet.member?(semantic_ids, to)
        end)

      assert tag_to_sem_links != []
      assert sibling_links != []
    end

    test "semantic nodes have provenance links to episodic nodes" do
      episode = build_closed_episode()
      stub_extraction_llm()

      {:ok, cs} = Structuring.extract(episode, @default_opts)

      semantic_ids =
        cs.additions
        |> Enum.filter(&match?(%Mnemosyne.Graph.Node.Semantic{}, &1))
        |> MapSet.new(& &1.id)

      episodic_ids =
        cs.additions
        |> Enum.filter(&match?(%Mnemosyne.Graph.Node.Episodic{}, &1))
        |> MapSet.new(& &1.id)

      provenance_links =
        Enum.filter(cs.links, fn {from, to} ->
          MapSet.member?(semantic_ids, from) and MapSet.member?(episodic_ids, to)
        end)

      # each semantic node links to each episodic node
      expected_count = MapSet.size(semantic_ids) * MapSet.size(episodic_ids)
      assert length(provenance_links) == expected_count
    end

    test "procedural nodes have provenance links to episodic nodes" do
      episode = build_closed_episode()
      stub_extraction_llm()

      {:ok, cs} = Structuring.extract(episode, @default_opts)

      procedural_ids =
        cs.additions
        |> Enum.filter(&match?(%Mnemosyne.Graph.Node.Procedural{}, &1))
        |> MapSet.new(& &1.id)

      episodic_ids =
        cs.additions
        |> Enum.filter(&match?(%Mnemosyne.Graph.Node.Episodic{}, &1))
        |> MapSet.new(& &1.id)

      provenance_links =
        Enum.filter(cs.links, fn {from, to} ->
          MapSet.member?(procedural_ids, from) and MapSet.member?(episodic_ids, to)
        end)

      expected_count = MapSet.size(procedural_ids) * MapSet.size(episodic_ids)
      assert length(provenance_links) == expected_count
    end

    test "tag and intent nodes have reward_count == 0" do
      episode = build_closed_episode()
      stub_extraction_llm()

      {:ok, cs} = Structuring.extract(episode, @default_opts)

      tag_ids =
        cs.additions
        |> Enum.filter(&match?(%Mnemosyne.Graph.Node.Tag{}, &1))
        |> Enum.map(& &1.id)

      intent_ids =
        cs.additions
        |> Enum.filter(&match?(%Mnemosyne.Graph.Node.Intent{}, &1))
        |> Enum.map(& &1.id)

      Enum.each(tag_ids ++ intent_ids, fn id ->
        meta = cs.metadata[id]
        assert %NodeMetadata{reward_count: 0} = meta
      end)
    end

    test "stamps return scores on procedural nodes" do
      episode = build_closed_episode()
      stub_extraction_llm()

      {:ok, cs} = Structuring.extract(episode, @default_opts)

      procedural_nodes =
        Enum.filter(cs.additions, &match?(%Mnemosyne.Graph.Node.Procedural{}, &1))

      assert [_ | _] = procedural_nodes

      Enum.each(procedural_nodes, fn node ->
        assert node.return_score != nil
        assert node.return_score >= 0.0 and node.return_score <= 1.0
      end)
    end

    test "uses per-prescription return scores in metadata" do
      episode = build_closed_episode()
      stub_extraction_llm()

      {:ok, cs} = Structuring.extract(episode, @default_opts)

      procedural_nodes =
        Enum.filter(cs.additions, &match?(%Mnemosyne.Graph.Node.Procedural{}, &1))

      Enum.each(procedural_nodes, fn node ->
        meta = cs.metadata[node.id]
        assert %NodeMetadata{cumulative_reward: reward, reward_count: 1} = meta
        assert reward == node.return_score
      end)
    end
  end

  describe "extract_trajectory/3" do
    test "extracts knowledge from a single trajectory into a changeset" do
      episode = build_closed_episode()
      stub_extraction_llm()

      trajectory = hd(episode.trajectories)
      opts = @default_opts ++ [episode_id: episode.id]

      assert {:ok, %Changeset{} = cs, _trace} =
               Structuring.extract_trajectory(trajectory, episode.goal, opts)

      assert [_ | _] = cs.additions
      assert [_ | _] = cs.links

      types = Enum.map(cs.additions, &struct_type/1) |> Enum.uniq() |> Enum.sort()
      assert :episodic in types
      assert :source in types
      assert :subgoal in types
      assert :semantic in types
      assert :tag in types
      assert :intent in types
      assert :procedural in types
    end

    test "uses generated fallback episode_id when not provided" do
      episode = build_closed_episode()
      stub_extraction_llm()

      trajectory = hd(episode.trajectories)

      assert {:ok, %Changeset{} = cs, _trace} =
               Structuring.extract_trajectory(trajectory, episode.goal, @default_opts)

      source_nodes = Enum.filter(cs.additions, &match?(%Mnemosyne.Graph.Node.Source{}, &1))
      assert [_ | _] = source_nodes
      assert Enum.all?(source_nodes, &(&1.episode_id != nil))
    end

    test "uses provided episode_id in source nodes" do
      episode = build_closed_episode()
      stub_extraction_llm()

      trajectory = hd(episode.trajectories)
      opts = @default_opts ++ [episode_id: "custom_ep_id"]

      assert {:ok, %Changeset{} = cs, _trace} =
               Structuring.extract_trajectory(trajectory, episode.goal, opts)

      source_nodes = Enum.filter(cs.additions, &match?(%Mnemosyne.Graph.Node.Source{}, &1))
      assert Enum.all?(source_nodes, &(&1.episode_id == "custom_ep_id"))
    end

    test "propagates LLM errors" do
      episode = build_closed_episode()

      Mnemosyne.MockLLM
      |> stub(:chat, fn _messages, _opts -> {:error, :extraction_failed} end)

      Mnemosyne.MockLLM
      |> stub(:chat_structured, fn _messages, _schema, _opts -> {:error, :extraction_failed} end)

      stub_default_embedding()

      trajectory = hd(episode.trajectories)

      assert {:error, :extraction_failed} =
               Structuring.extract_trajectory(trajectory, episode.goal, @default_opts)
    end
  end

  defp node_id(%{id: id}), do: id

  defp struct_type(%Mnemosyne.Graph.Node.Episodic{}), do: :episodic
  defp struct_type(%Mnemosyne.Graph.Node.Semantic{}), do: :semantic
  defp struct_type(%Mnemosyne.Graph.Node.Procedural{}), do: :procedural
  defp struct_type(%Mnemosyne.Graph.Node.Source{}), do: :source
  defp struct_type(%Mnemosyne.Graph.Node.Subgoal{}), do: :subgoal
  defp struct_type(%Mnemosyne.Graph.Node.Tag{}), do: :tag
  defp struct_type(%Mnemosyne.Graph.Node.Intent{}), do: :intent
  defp struct_type(_), do: :unknown
end
