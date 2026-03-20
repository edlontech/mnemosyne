defmodule Mnemosyne.Notifier.Trace.Episode do
  @moduledoc """
  Trace struct capturing episode pipeline execution details.
  """

  use TypedStruct

  typedstruct do
    field :verbosity, :summary | :detailed, default: :summary

    field :step_index, non_neg_integer(), default: 0
    field :trajectory_id, String.t()
    field :boundary_detected, boolean(), default: false
    field :reward, float(), default: 0.0
    field :duration_us, non_neg_integer(), default: 0

    field :subgoal, String.t(), default: nil
    field :similarity_score, float(), default: nil
    field :similarity_threshold, float(), default: nil
  end
end
