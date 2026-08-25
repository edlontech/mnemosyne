defmodule Mnemosyne.GraphBackend do
  @moduledoc """
  Behaviour for unified graph persistence and querying backends.

  Implementations handle storing, retrieving, and querying knowledge graph
  nodes through a single interface, replacing the separate Storage and
  in-memory Graph modules with a database-agnostic contract.

  ## Callbacks

  - `init/1` - Initialize the backend with configuration options.
  - `apply_changeset/2` - Persist a batch of node additions and links.
  - `get_ingestion/2` - Fetch a durable ingestion record by source ID.
  - `commit_ingestion/3` - Compare-and-set graph changes and an ingestion record, reporting whether it inserted or found an equal record.
  - `delete_nodes/2` - Remove nodes by their IDs.
  - `find_candidates/6` - Query for nodes matching type/embedding/tag criteria.
  - `get_node/2` - Fetch a single node by ID.
  - `get_linked_nodes/3` - Fetch linked nodes, optionally filtered by edge type.

  Read callbacks (`find_candidates`, `get_node`, `get_linked_nodes`, `get_ingestion`)
  return state
  for interface uniformity but must not rely on state mutation — callers may
  discard the returned state in read-only contexts.
  """

  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Edge

  @type state :: term()
  @type scored_node :: {struct(), float()}
  @type ingestion_record :: %{
          source_id: String.t(),
          payload_digest: binary(),
          fingerprint_version: pos_integer(),
          receipt: Mnemosyne.IngestionReceipt.t()
        }

  @callback init(opts :: keyword()) ::
              {:ok, state()} | {:error, Mnemosyne.Errors.error()}

  @callback apply_changeset(Changeset.t(), state()) ::
              {:ok, state()} | {:error, Mnemosyne.Errors.error()}

  @callback get_ingestion(String.t(), state()) ::
              {:ok, ingestion_record() | nil, state()} | {:error, Mnemosyne.Errors.error()}

  @callback commit_ingestion(ingestion_record(), Changeset.t(), state()) ::
              {:ok, :inserted | :existing, Mnemosyne.IngestionReceipt.t(), state()}
              | {:error, Mnemosyne.Errors.error()}

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

  @callback get_linked_nodes([String.t()], Edge.edge_type() | nil, state()) ::
              {:ok, [struct()], state()}

  @callback get_metadata([String.t()], state()) ::
              {:ok, %{String.t() => struct()}, state()}

  @callback update_metadata(%{String.t() => struct()}, state()) ::
              {:ok, state()}

  @callback delete_metadata([String.t()], state()) ::
              {:ok, state()}

  @callback get_nodes_by_type(node_types :: [atom()], state()) ::
              {:ok, [struct()], state()} | {:error, Mnemosyne.Errors.error()}
end
