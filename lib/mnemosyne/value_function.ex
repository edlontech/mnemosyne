defmodule Mnemosyne.ValueFunction do
  @moduledoc """
  Behaviour for scoring and filtering memory nodes.

  Implementations define how relevance scores are computed,
  what threshold to apply, and how many top results to return.
  """

  @callback score(relevance :: float(), node :: struct()) :: float()
  @callback threshold() :: float()
  @callback top_k() :: pos_integer()
end
