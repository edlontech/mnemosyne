defmodule Mnemosyne.GraphBackends.InMemory do
  @moduledoc """
  In-memory graph backend wrapping `Mnemosyne.Graph`.

  Stores all nodes in a plain `Graph` struct and scores candidates
  using cosine similarity and value functions.
  """

  @behaviour Mnemosyne.GraphBackend

  use TypedStruct

  alias Mnemosyne.Graph
  alias Mnemosyne.Graph.Node, as: NodeProtocol
  alias Mnemosyne.Graph.Similarity

  typedstruct do
    field :graph, Graph.t(), default: Graph.new()
    field :persistence, {module(), term()} | nil, default: nil
    field :metadata, %{String.t() => Mnemosyne.NodeMetadata.t()}, default: %{}
  end

  @impl true
  def init(opts) do
    case Keyword.get(opts, :persistence) do
      nil ->
        {:ok, %__MODULE__{}}

      {mod, persistence_opts} ->
        with {:ok, ps} <- mod.init(persistence_opts),
             {:ok, graph, metadata} <- mod.load(ps) do
          {:ok, %__MODULE__{graph: graph, persistence: {mod, ps}, metadata: metadata}}
        end
    end
  end

  @impl true
  def apply_changeset(changeset, state) do
    updated_graph = Graph.apply_changeset(state.graph, changeset)
    :ok = maybe_persist(changeset, state.persistence)
    {:ok, %{state | graph: updated_graph}}
  end

  @impl true
  def delete_nodes(node_ids, state) do
    updated_graph = Enum.reduce(node_ids, state.graph, &Graph.delete_node(&2, &1))
    :ok = maybe_delete(node_ids, state.persistence)
    {:ok, %{state | graph: updated_graph}}
  end

  @impl true
  def find_candidates(node_types, query_vector, tag_vectors, vf_config, _opts, state) do
    candidates =
      node_types
      |> Enum.flat_map(
        &score_type(state.graph, &1, query_vector, tag_vectors, vf_config, state.metadata)
      )
      |> Enum.uniq_by(fn {node, _score} -> NodeProtocol.id(node) end)

    {:ok, candidates, state}
  end

  @impl true
  def get_node(id, state) do
    {:ok, Graph.get_node(state.graph, id), state}
  end

  @impl true
  def get_linked_nodes(node_ids, state) do
    nodes =
      node_ids
      |> Enum.map(&Graph.get_node(state.graph, &1))
      |> Enum.reject(&is_nil/1)

    {:ok, nodes, state}
  end

  defp score_type(graph, type, query_vector, tag_vectors, vf_config, metadata) do
    vf_module = Map.get(vf_config, :module, Mnemosyne.ValueFunction.Default)
    nodes = Graph.nodes_by_type(graph, type)
    params = get_in(vf_config, [:params, type]) || %{}
    threshold = Map.get(params, :threshold, 0.0)
    k = Map.get(params, :top_k, 20)

    candidates =
      Enum.map(nodes, fn node ->
        emb = NodeProtocol.embedding(node)
        relevance = compute_relevance(emb, query_vector, tag_vectors)
        node_meta = Map.get(metadata, NodeProtocol.id(node))
        score = vf_module.score(relevance, node, node_meta, params)
        {node, score}
      end)

    candidates
    |> Enum.filter(fn {_node, score} -> score >= threshold end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(k)
  end

  defp compute_relevance(nil, _query_vector, _tag_vectors), do: 0.0

  defp compute_relevance(emb, query_vector, tag_vectors) do
    query_sim = Similarity.cosine_similarity(query_vector, emb)

    tag_sim =
      tag_vectors
      |> Enum.map(&Similarity.cosine_similarity(&1, emb))
      |> Enum.max(fn -> 0.0 end)

    max(query_sim, tag_sim) |> max(0.0)
  end

  @impl true
  def get_metadata(node_ids, state) do
    result = Map.take(state.metadata, node_ids)
    {:ok, result, state}
  end

  @impl true
  def update_metadata(entries, state) do
    updated = Map.merge(state.metadata, entries)
    :ok = maybe_persist_metadata(entries, state.persistence)
    {:ok, %{state | metadata: updated}}
  end

  @impl true
  def get_nodes_by_type(node_types, state) do
    nodes = Enum.flat_map(node_types, &Graph.nodes_by_type(state.graph, &1))
    {:ok, nodes, state}
  end

  @impl true
  def delete_metadata(node_ids, state) do
    updated = Map.drop(state.metadata, node_ids)
    :ok = maybe_delete_metadata(node_ids, state.persistence)
    {:ok, %{state | metadata: updated}}
  end

  defp maybe_persist(_changeset, nil), do: :ok
  defp maybe_persist(changeset, {mod, ps}), do: mod.save(changeset, ps)

  defp maybe_delete(_ids, nil), do: :ok
  defp maybe_delete(ids, {mod, ps}), do: mod.delete(ids, ps)

  defp maybe_persist_metadata(_entries, nil), do: :ok
  defp maybe_persist_metadata(entries, {mod, ps}), do: mod.save_metadata(entries, ps)

  defp maybe_delete_metadata(_ids, nil), do: :ok
  defp maybe_delete_metadata(ids, {mod, ps}), do: mod.delete_metadata(ids, ps)
end
