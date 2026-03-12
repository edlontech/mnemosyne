defmodule Mnemosyne.Storage do
  @moduledoc """
  Behaviour for graph persistence backends.

  Implementations handle loading, persisting, and deleting
  graph data from a backing store.
  """

  # TODO: Replace term() with Graph.t() and Graph.Changeset.t() once those types are defined.

  @type state :: term()

  @callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}
  @callback load_graph(state()) :: {:ok, term()} | {:error, term()}
  @callback persist_changeset(changeset :: term(), state()) :: :ok | {:error, term()}
  @callback delete_nodes(node_ids :: [String.t()], state()) :: :ok | {:error, term()}
end
