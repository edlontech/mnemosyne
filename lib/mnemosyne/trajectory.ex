defmodule Mnemosyne.Trajectory do
  @moduledoc """
  Caller-owned completed history submitted for ingestion.
  """

  @enforce_keys [:source_id, :goal, :steps]
  defstruct [:source_id, :goal, steps: [], metadata: %{}]

  @typedoc "A raw observation-action pair."
  @type step :: %{
          required(:observation) => String.t(),
          required(:action) => String.t()
        }

  @type t :: %__MODULE__{
          source_id: String.t(),
          goal: String.t(),
          steps: [step()],
          metadata: map()
        }
end
