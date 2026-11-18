defmodule Mnemosyne.Pipeline.Ingestion do
  @moduledoc """
  Validates complete trajectories and computes their stable payload identity.
  """

  alias Mnemosyne.Errors.Invalid.IngestionError
  alias Mnemosyne.Graph.Node, as: NodeProtocol
  alias Mnemosyne.Pipeline.Episode
  alias Mnemosyne.Pipeline.Structuring
  alias Mnemosyne.Trajectory

  @fingerprint_version 1
  @external_term_minor_version 2
  @content_types [:episodic, :source, :subgoal, :semantic, :procedural]

  @doc "Returns the version used by the current payload fingerprint."
  @spec fingerprint_version() :: pos_integer()
  def fingerprint_version, do: @fingerprint_version

  @doc """
  Validates a trajectory and returns its versioned SHA-256 payload digest.
  """
  @spec prepare(Trajectory.t()) :: {:ok, binary()} | {:error, IngestionError.t()}
  def prepare(%Trajectory{} = trajectory) do
    with :ok <- validate(trajectory),
         {:ok, audience} <- normalize_audience(trajectory.audience) do
      {:ok, fingerprint(%{trajectory | audience: audience})}
    else
      {:error, reason} ->
        {:error, IngestionError.exception(source_id: trajectory.source_id, reason: reason)}
    end
  end

  def prepare(_trajectory) do
    {:error, IngestionError.exception(reason: :invalid_trajectory)}
  end

  @doc "Transforms a complete trajectory into a graph changeset."
  @spec run(Trajectory.t(), keyword()) ::
          {:ok, Mnemosyne.Graph.Changeset.t()} | {:error, Mnemosyne.Errors.error()}
  def run(%Trajectory{} = trajectory, opts) do
    opts = Keyword.put(opts, :source_id, trajectory.source_id)

    episode =
      Episode.new(trajectory.goal, id: trajectory.source_id, occurred_at: trajectory.occurred_at)

    with {:ok, episode} <- Episode.standardize(episode, trajectory.steps, opts),
         {:ok, changeset} <- Structuring.extract(episode, opts) do
      metadata =
        Map.new(changeset.metadata, fn {id, meta} ->
          {id, %{meta | custom: trajectory.metadata}}
        end)

      {:ok, stamp_occurred_at(%{changeset | metadata: metadata}, trajectory.occurred_at)}
    end
  end

  defp stamp_occurred_at(changeset, nil), do: changeset

  defp stamp_occurred_at(changeset, occurred_at) do
    additions =
      Enum.map(changeset.additions, fn node ->
        if NodeProtocol.node_type(node) in @content_types,
          do: %{node | created_at: occurred_at},
          else: node
      end)

    %{changeset | additions: additions}
  end

  defp normalize_audience(nil), do: {:ok, nil}

  defp normalize_audience(audience) do
    case Mnemosyne.AccessControl.normalize_audience(audience) do
      {:ok, audience} -> {:ok, audience}
      {:error, _} -> {:error, :invalid_audience}
    end
  end

  defp validate(trajectory) do
    cond do
      not non_blank_binary?(trajectory.source_id) -> {:error, :invalid_source_id}
      not non_blank_binary?(trajectory.goal) -> {:error, :invalid_goal}
      not valid_metadata?(trajectory.metadata) -> {:error, :invalid_metadata}
      not valid_occurred_at?(trajectory.occurred_at) -> {:error, :invalid_occurred_at}
      true -> validate_steps(trajectory.steps)
    end
  end

  defp fingerprint(trajectory) do
    identity =
      {:mnemosyne_trajectory, @fingerprint_version, trajectory.goal,
       Enum.map(trajectory.steps, &{&1.observation, &1.action}), trajectory.metadata}

    # Wrapped only when set, so payloads stored before this field keep their digest.
    identity =
      case trajectory.occurred_at do
        nil ->
          identity

        occurred_at ->
          {:mnemosyne_occurred_at, @fingerprint_version,
           DateTime.to_unix(occurred_at, :microsecond), identity}
      end

    identity =
      case trajectory.audience do
        nil -> identity
        audience -> {:mnemosyne_audience, @fingerprint_version, audience, identity}
      end

    :crypto.hash(
      :sha256,
      :erlang.term_to_binary(identity, [
        :deterministic,
        minor_version: @external_term_minor_version
      ])
    )
  end

  defp non_blank_binary?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_blank_binary?(_value), do: false

  defp validate_steps(steps) when is_list(steps) and steps != [] do
    if List.improper?(steps) do
      {:error, :invalid_steps}
    else
      if Enum.all?(steps, &valid_step?/1), do: :ok, else: {:error, :invalid_step}
    end
  end

  defp validate_steps(_steps), do: {:error, :invalid_steps}

  defp valid_step?(%{observation: observation, action: action}) do
    is_binary(observation) and is_binary(action)
  end

  defp valid_step?(_step), do: false

  defp valid_occurred_at?(occurred_at),
    do: is_nil(occurred_at) or is_struct(occurred_at, DateTime)

  defp valid_metadata?(metadata) when is_map(metadata), do: deterministic_term?(metadata)
  defp valid_metadata?(_metadata), do: false

  defp deterministic_term?(term)
       when is_nil(term) or is_boolean(term) or is_number(term) or is_binary(term) or
              is_atom(term),
       do: true

  defp deterministic_term?([]), do: true

  defp deterministic_term?([head | tail]),
    do: deterministic_term?(head) and deterministic_term?(tail)

  defp deterministic_term?(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.all?(&deterministic_term?/1)

  defp deterministic_term?(term) when is_map(term) do
    term
    |> Map.to_list()
    |> Enum.all?(fn {key, value} -> deterministic_term?(key) and deterministic_term?(value) end)
  end

  defp deterministic_term?(_term), do: false
end
