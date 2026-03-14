defmodule Mnemosyne.GraphBackend do
  @moduledoc """
  Behaviour for unified graph persistence and querying backends.

  Implementations handle storing, retrieving, and querying knowledge graph
  nodes through a single interface, replacing the separate Storage and
  in-memory Graph modules with a database-agnostic contract.

  ## Callbacks

  - `init/1` - Initialize the backend with configuration options.
  - `apply_changeset/2` - Persist a batch of node additions and links.
  - `delete_nodes/2` - Remove nodes by their IDs.
  - `find_candidates/6` - Query for nodes matching type/embedding/tag criteria.
  - `get_node/2` - Fetch a single node by ID.
  - `get_linked_nodes/2` - Fetch nodes by their IDs.

  Read callbacks (`find_candidates`, `get_node`, `get_linked_nodes`) return state
  for interface uniformity but must not rely on state mutation — callers may
  discard the returned state in read-only contexts.
  """

  alias Mnemosyne.Graph.Changeset

  @type state :: term()
  @type scored_node :: {struct(), float()}

  @callback init(opts :: keyword()) ::
              {:ok, state()} | {:error, Mnemosyne.Errors.error()}

  @callback apply_changeset(Changeset.t(), state()) ::
              {:ok, state()} | {:error, Mnemosyne.Errors.error()}

  @callback delete_nodes([String.t()], state()) ::
              {:ok, state()} | {:error, Mnemosyne.Errors.error()}

  @callback find_candidates(
              node_types :: [atom()],
              query_embedding :: [float()],
              tag_embeddings :: [[float()]],
              value_fn_config :: %{module: module(), params: %{atom() => map()}},
              opts :: keyword(),
              state()
            ) ::
              {:ok, [scored_node()], state()} | {:error, Mnemosyne.Errors.error()}

  @callback get_node(String.t(), state()) ::
              {:ok, struct() | nil, state()}

  @callback get_linked_nodes([String.t()], state()) ::
              {:ok, [struct()], state()}

  @callback get_metadata([String.t()], state()) ::
              {:ok, %{String.t() => struct()}, state()}

  @callback update_metadata(%{String.t() => struct()}, state()) ::
              {:ok, state()}

  @callback delete_metadata([String.t()], state()) ::
              {:ok, state()}
end
