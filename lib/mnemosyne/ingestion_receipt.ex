defmodule Mnemosyne.IngestionReceipt do
  @moduledoc """
  The durable result of a trajectory ingestion.
  """

  @enforce_keys [:source_id, :node_ids, :stored_at]
  defstruct [:source_id, :node_ids, :stored_at]

  @type t :: %__MODULE__{
          source_id: String.t(),
          node_ids: [String.t()],
          stored_at: DateTime.t()
        }
end
