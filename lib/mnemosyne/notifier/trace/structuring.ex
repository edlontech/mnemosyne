defmodule Mnemosyne.Notifier.Trace.Structuring do
  @moduledoc """
  Trace struct capturing structuring pipeline execution details.
  """

  use TypedStruct

  typedstruct do
    field :verbosity, :summary | :detailed, default: :summary

    field :trajectory_id, String.t()
    field :semantic_count, non_neg_integer(), default: 0
    field :procedural_count, non_neg_integer(), default: 0
    field :tag_count, non_neg_integer(), default: 0
    field :intent_count, non_neg_integer(), default: 0
    field :duration_us, non_neg_integer(), default: 0

    field :semantic_nodes, [map()], default: nil
    field :procedural_nodes, [map()], default: nil
    field :merged_intents, [map()], default: nil
    field :phase_timings, map(), default: nil
  end
end
