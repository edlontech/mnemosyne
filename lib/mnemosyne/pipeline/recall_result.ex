defmodule Mnemosyne.Pipeline.RecallResult do
  @moduledoc """
  Result of a recall operation containing reasoned summaries,
  touched nodes, and execution trace.
  """

  alias Mnemosyne.Notifier.Trace.Recall, as: RecallTrace
  alias Mnemosyne.Pipeline.Reasoning.ReasonedMemory
  alias Mnemosyne.Pipeline.Retrieval.TouchedNode

  defstruct [:reasoned, :trace, touched_nodes: [], reasoned_ids: %{}]

  @typedoc """
  `touched_nodes` is every candidate retrieval surfaced. `reasoned_ids` holds,
  per node type, the IDs of the candidates the reasoner actually read (the
  per-type `top_k` cut); resolve them with `Mnemosyne.get_sources/3`.
  """
  @type t :: %__MODULE__{
          reasoned: ReasonedMemory.t(),
          reasoned_ids: %{atom() => [String.t()]},
          touched_nodes: [TouchedNode.t()],
          trace: RecallTrace.t()
        }
end
