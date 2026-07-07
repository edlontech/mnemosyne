defmodule Mnemosyne.Pipeline.Prompts.MultiHopControl do
  @moduledoc """
  Prompt for controlling the multi-hop retrieval loop.

  Given the query and the candidates retrieved so far, decides whether
  the accumulated evidence is sufficient to stop retrieval, and if not,
  selects a small focus set of candidates that should drive the next hop.

  Returns structured output via `chat_structured/3` using a Zoi schema.
  """

  alias Mnemosyne.Errors.Invalid.PromptError

  @doc "Returns the Zoi schema for structured LLM output validation."
  @spec schema :: Zoi.Type.t()
  def schema do
    Zoi.map(
      %{
        enough: Zoi.boolean(),
        top_indices: Zoi.list(Zoi.integer())
      },
      coerce: true
    )
  end

  @doc "Builds the system and user messages for the retrieval control prompt."
  @spec build_messages(map()) :: [map()]
  def build_messages(%{query: query, candidates: candidates, max_focus: max_focus} = variables) do
    overlay = if variables[:overlay], do: "\n\n#{variables.overlay}", else: ""

    formatted_candidates =
      Enum.map_join(candidates, "\n", fn c ->
        "[#{c.index}] (#{c.type}) #{c.content}"
      end)

    [
      %{
        role: :system,
        content:
          """
          You are a retrieval controller for multi-hop memory retrieval.
          Given a query and the memory candidates retrieved so far, decide whether
          the candidates already contain enough evidence to answer the query.

          Return a JSON object with:
          - "enough": true if the retrieved candidates are sufficient to answer the query
          - "top_indices": if not sufficient, up to #{max_focus} indices of the most
            promising candidates whose content should guide the next retrieval hop
            (e.g. candidates naming a bridge entity that must be resolved next)

          Constraints:
          - top_indices must be a subset of the shown candidate indices
          - top_indices length must be at most #{max_focus}
          - if enough is true, top_indices must be an empty list\
          """ <> overlay
      },
      %{
        role: :user,
        content: """
        Query: #{query}

        Retrieved candidates:
        #{formatted_candidates}\
        """
      }
    ]
  end

  @doc "Parses the control decision from the LLM response."
  @spec parse_response(map()) ::
          {:ok, %{enough: boolean(), top_indices: [integer()]}} | {:error, PromptError.t()}
  def parse_response(%{enough: enough, top_indices: indices})
      when is_boolean(enough) and is_list(indices) do
    indices = Enum.filter(indices, &is_integer/1)
    {:ok, %{enough: enough, top_indices: if(enough, do: [], else: indices)}}
  end

  def parse_response(_) do
    {:error, PromptError.exception(prompt: :multi_hop_control, reason: :invalid_decision)}
  end
end
