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

    field :candidates_per_hop, %{non_neg_integer() => non_neg_integer()} | nil, default: nil
    field :scores, %{String.t() => float()} | nil, default: nil
    field :rejected, %{atom() => non_neg_integer()} | nil, default: nil
    field :phase_timings, %{atom() => non_neg_integer()} | nil, default: nil
  end
end
