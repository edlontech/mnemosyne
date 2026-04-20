defmodule Mnemosyne.Notifier.Trace.Episode do
  @moduledoc """
  Trace struct capturing episode pipeline execution details.
  """

  defstruct verbosity: :summary,
            step_index: 0,
            trajectory_id: nil,
            boundary_detected: false,
            reward: 0.0,
            duration_us: 0,
            subgoal: nil,
            similarity_score: nil,
            similarity_threshold: nil

  @type t :: %__MODULE__{
          verbosity: :summary | :detailed,
          step_index: non_neg_integer(),
          trajectory_id: String.t(),
          boundary_detected: boolean(),
          reward: float(),
          duration_us: non_neg_integer(),
          subgoal: String.t(),
          similarity_score: float(),
          similarity_threshold: float()
        }
end
