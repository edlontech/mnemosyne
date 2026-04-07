defmodule Mnemosyne.QueryApiTest do
  use ExUnit.Case, async: true
  use AssertEventually, timeout: 500, interval: 10

  alias Mnemosyne.Errors.Framework.NotFoundError
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Tag
  alias Mnemosyne.GraphBackends.InMemory
  alias Mnemosyne.NodeMetadata
  alias Mnemosyne.Supervisor, as: MneSupervisor

  @moduletag :tmp_dir

  defp build_config do
    {:ok, config} =
      Zoi.parse(Mnemosyne.Config.t(), %{
        llm: %{model: "test-model", opts: %{}},
        embedding: %{model: "test-embed", opts: %{}}
      })

    config
  end

  defp start_sup(_ctx) do
    name = :"sup_#{System.unique_integer([:positive])}"

    opts = [
      name: name,
      config: build_config(),
      llm: Mnemosyne.MockLLM,
      embedding: Mnemosyne.MockEmbedding
    ]

    start_supervised!({MneSupervisor, opts})
    name
  end

  defp open_repo(sup) do
    repo_id = "repo-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Mnemosyne.open_repo(repo_id, backend: {InMemory, []}, supervisor: sup)
    repo_id
  end

  defp seed_graph(repo_id, sup) do
    tag = %Tag{id: "t1", label: "elixir", links: %{membership: MapSet.new(["s1"])}}

    sem = %Semantic{
      id: "s1",
      proposition: "Elixir is functional",
      confidence: 0.9,
      links: %{membership: MapSet.new(["t1"])}
    }

    meta = NodeMetadata.new(created_at: DateTime.utc_now(), access_count: 3)

    changeset =
      Changeset.new()
      |> Changeset.add_node(tag)
      |> Changeset.add_node(sem)
      |> Changeset.put_metadata("s1", meta)

    :ok = Mnemosyne.apply_changeset(repo_id, changeset, supervisor: sup)
    {sem, tag, meta}
  end

  setup %{tmp_dir: tmp_dir} do
    sup = start_sup(tmp_dir)
    repo_id = open_repo(sup)
    {_sem, _tag, _meta} = seed_graph(repo_id, sup)

    assert_eventually(
      match?({:ok, %Semantic{}}, Mnemosyne.get_node(repo_id, "s1", supervisor: sup))
    )

    %{sup: sup, repo_id: repo_id}
  end

  describe "get_node/3" do
    test "returns existing node by ID", %{repo_id: repo_id, sup: sup} do
      assert {:ok, %Semantic{id: "s1", proposition: "Elixir is functional"}} =
               Mnemosyne.get_node(repo_id, "s1", supervisor: sup)
    end

    test "returns nil for unknown ID", %{repo_id: repo_id, sup: sup} do
      assert {:ok, nil} = Mnemosyne.get_node(repo_id, "nonexistent", supervisor: sup)
    end
  end

  describe "get_nodes_by_type/3" do
    test "returns nodes of requested types", %{repo_id: repo_id, sup: sup} do
      assert {:ok, nodes} = Mnemosyne.get_nodes_by_type(repo_id, [:semantic], supervisor: sup)
      assert [%Semantic{id: "s1"}] = nodes
    end

    test "returns empty list for unused types", %{repo_id: repo_id, sup: sup} do
      assert {:ok, []} = Mnemosyne.get_nodes_by_type(repo_id, [:procedural], supervisor: sup)
    end

    test "returns multiple types", %{repo_id: repo_id, sup: sup} do
      assert {:ok, nodes} =
               Mnemosyne.get_nodes_by_type(repo_id, [:semantic, :tag], supervisor: sup)

      ids = Enum.map(nodes, & &1.id) |> Enum.sort()
      assert ids == ["s1", "t1"]
    end
  end

  describe "get_metadata/3" do
    test "returns metadata for known nodes", %{repo_id: repo_id, sup: sup} do
      assert {:ok, metadata} = Mnemosyne.get_metadata(repo_id, ["s1"], supervisor: sup)
      assert %{"s1" => %NodeMetadata{access_count: 3}} = metadata
    end

    test "returns empty map for unknown node IDs", %{repo_id: repo_id, sup: sup} do
      assert {:ok, metadata} = Mnemosyne.get_metadata(repo_id, ["unknown"], supervisor: sup)
      assert metadata == %{}
    end
  end

  describe "get_linked_nodes/3" do
    test "returns nodes by IDs (batch fetch)", %{repo_id: repo_id, sup: sup} do
      assert {:ok, nodes} = Mnemosyne.get_linked_nodes(repo_id, ["t1", "s1"], supervisor: sup)
      ids = Enum.map(nodes, & &1.id) |> Enum.sort()
      assert ids == ["s1", "t1"]
    end

    test "returns empty list for unknown IDs", %{repo_id: repo_id, sup: sup} do
      assert {:ok, []} = Mnemosyne.get_linked_nodes(repo_id, ["nonexistent"], supervisor: sup)
    end
  end

  describe "error cases" do
    test "returns NotFoundError for non-existent repo", %{sup: sup} do
      assert {:error, %NotFoundError{resource: :repo}} =
               Mnemosyne.get_node("ghost-repo", "s1", supervisor: sup)
    end
  end
end
