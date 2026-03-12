defmodule Mnemosyne.Storage do
  @moduledoc """
  Behaviour for graph persistence backends.

  Implementations handle loading, persisting, and deleting
  graph data from a backing store.
  """

  @type state :: term()

  @callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}
  @callback load_graph(state()) :: {:ok, term()} | {:error, term()}
  @callback persist_changeset(changeset :: term(), state()) :: :ok | {:error, term()}
  @callback delete_nodes(node_ids :: [String.t()], state()) :: :ok | {:error, term()}
end
