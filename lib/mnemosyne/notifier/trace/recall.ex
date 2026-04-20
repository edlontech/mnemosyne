defmodule Mnemosyne.Notifier.Trace.Recall do
  @moduledoc """
  Trace struct capturing recall pipeline execution details.
  """

  defstruct verbosity: :summary,
            mode: nil,
            tags: [],
            candidate_count: 0,
            hops: 0,
            result_count: 0,
            duration_us: 0,
            candidates_per_hop: nil,
            scores: nil,
            rejected: nil,
            phase_timings: nil,
            refinements: []

  @type t :: %__MODULE__{
          verbosity: :summary | :detailed,
          mode: atom(),
          tags: [String.t()],
          candidate_count: non_neg_integer(),
          hops: non_neg_integer(),
          result_count: non_neg_integer(),
          duration_us: non_neg_integer(),
          candidates_per_hop: %{non_neg_integer() => non_neg_integer()} | nil,
          scores: %{String.t() => float()} | nil,
          rejected: %{atom() => non_neg_integer()} | nil,
          phase_timings: %{atom() => non_neg_integer()} | nil,
          refinements: [map()]
        }
end
