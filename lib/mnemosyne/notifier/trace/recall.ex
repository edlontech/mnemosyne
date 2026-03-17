defmodule Mnemosyne.Notifier.Trace.Recall do
  @moduledoc """
  Trace struct capturing recall pipeline execution details.
  """

  use TypedStruct

  typedstruct do
    field :verbosity, :summary | :detailed, default: :summary

    field :mode, atom()
    field :tags, [String.t()], default: []
    field :candidate_count, non_neg_integer(), default: 0
    field :hops, non_neg_integer(), default: 0
    field :result_count, non_neg_integer(), default: 0
    field :duration_us, non_neg_integer(), default: 0

    field :candidates_per_hop, [map()], default: nil
    field :scores, [map()], default: nil
    field :rejected, [map()], default: nil
    field :phase_timings, map(), default: nil
  end
end
