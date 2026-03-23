defmodule Mnemosyne.Pipeline.RecallResult do
  @moduledoc """
  Result of a recall operation containing reasoned summaries,
  touched nodes, and execution trace.
  """

  use TypedStruct

  alias Mnemosyne.Notifier.Trace.Recall, as: RecallTrace
  alias Mnemosyne.Pipeline.Reasoning.ReasonedMemory
  alias Mnemosyne.Pipeline.Retrieval.TouchedNode

  typedstruct do
    field :reasoned, ReasonedMemory.t()
    field :touched_nodes, [TouchedNode.t()], default: []
    field :trace, RecallTrace.t()
  end
end
