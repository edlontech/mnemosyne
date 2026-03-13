defmodule Mnemosyne.Storage do
  @moduledoc """
  Behaviour for graph persistence backends.

  Implementations handle loading, persisting, and deleting
  graph data from a backing store.
  """

  @type state :: term()

  @callback init(opts :: keyword()) ::
              {:ok, state()} | {:error, Mnemosyne.Errors.Framework.StorageError.t()}
  @callback load_graph(state()) ::
              {:ok, term()} | {:error, Mnemosyne.Errors.Framework.StorageError.t()}
  @callback persist_changeset(changeset :: term(), state()) ::
              :ok | {:error, Mnemosyne.Errors.Framework.StorageError.t()}
  @callback delete_nodes(node_ids :: [String.t()], state()) ::
              :ok | {:error, Mnemosyne.Errors.Framework.StorageError.t()}
end
