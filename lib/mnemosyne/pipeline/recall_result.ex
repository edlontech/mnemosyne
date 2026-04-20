defmodule Mnemosyne.Pipeline.RecallResult do
  @moduledoc """
  Result of a recall operation containing reasoned summaries,
  touched nodes, and execution trace.
  """

  alias Mnemosyne.Notifier.Trace.Recall, as: RecallTrace
  alias Mnemosyne.Pipeline.Reasoning.ReasonedMemory
  alias Mnemosyne.Pipeline.Retrieval.TouchedNode

  defstruct [:reasoned, :trace, touched_nodes: []]

  @type t :: %__MODULE__{
          reasoned: ReasonedMemory.t(),
          touched_nodes: [TouchedNode.t()],
          trace: RecallTrace.t()
        }
end
