defmodule Mnemosyne.Trajectory do
  @moduledoc """
  Caller-owned completed history submitted for ingestion.

  Protected repos require an explicit `audience`: `:repo` or a nonempty list of
  `{organization_id, group_id}` tuples. It is immutable, part of payload identity,
  and inherited by every extracted node. Unrestricted repos use nil.
  """

  @enforce_keys [:source_id, :goal, :steps]
  defstruct [:source_id, :goal, :audience, steps: [], metadata: %{}]

  @typedoc "A raw observation-action pair."
  @type step :: %{
          required(:observation) => String.t(),
          required(:action) => String.t()
        }

  @type t :: %__MODULE__{
          source_id: String.t(),
          goal: String.t(),
          audience: :repo | [{String.t(), String.t()}] | nil,
          steps: [step()],
          metadata: map()
        }
end
