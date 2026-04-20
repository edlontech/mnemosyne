defmodule Mnemosyne.Notifier.Trace.Structuring do
  @moduledoc """
  Trace struct capturing structuring pipeline execution details.
  """

  defstruct verbosity: :summary,
            trajectory_id: nil,
            semantic_count: 0,
            procedural_count: 0,
            tag_count: 0,
            intent_count: 0,
            duration_us: 0,
            semantic_nodes: nil,
            procedural_nodes: nil,
            merged_intents: nil,
            phase_timings: nil

  @type t :: %__MODULE__{
          verbosity: :summary | :detailed,
          trajectory_id: String.t(),
          semantic_count: non_neg_integer(),
          procedural_count: non_neg_integer(),
          tag_count: non_neg_integer(),
          intent_count: non_neg_integer(),
          duration_us: non_neg_integer(),
          semantic_nodes: [map()] | nil,
          procedural_nodes: [map()] | nil,
          merged_intents: [map()] | nil,
          phase_timings: map() | nil
        }
end
