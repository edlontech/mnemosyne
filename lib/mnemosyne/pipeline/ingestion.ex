defmodule Mnemosyne.Pipeline.Ingestion do
  @moduledoc """
  Validates complete trajectories and computes their stable payload identity.
  """

  alias Mnemosyne.Errors.Invalid.IngestionError
  alias Mnemosyne.Pipeline.Episode
  alias Mnemosyne.Pipeline.Structuring
  alias Mnemosyne.Trajectory

  @fingerprint_version 1
  @external_term_minor_version 2

  @doc """
  Validates a trajectory and returns its versioned SHA-256 payload digest.
  """
  @spec prepare(Trajectory.t()) :: {:ok, binary()} | {:error, IngestionError.t()}
  def prepare(%Trajectory{} = trajectory) do
    case validate(trajectory) do
      :ok ->
        {:ok, fingerprint(trajectory)}

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
    episode = Episode.new(trajectory.goal, id: trajectory.source_id)

    with {:ok, episode} <- append_steps(episode, trajectory.steps, opts),
         {:ok, episode} <- Episode.score_pending_reward(episode, opts),
         {:ok, episode} <- Episode.close(episode) do
      Structuring.extract(episode, opts)
    end
  end

  defp append_steps(episode, steps, opts) do
    Enum.reduce_while(steps, {:ok, episode}, fn %{observation: observation, action: action},
                                                {:ok, episode} ->
      case Episode.append(episode, observation, action, opts) do
        {:ok, episode, _trace} -> {:cont, {:ok, episode}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate(trajectory) do
    cond do
      not non_blank_binary?(trajectory.source_id) -> {:error, :invalid_source_id}
      not non_blank_binary?(trajectory.goal) -> {:error, :invalid_goal}
      not valid_metadata?(trajectory.metadata) -> {:error, :invalid_metadata}
      true -> validate_steps(trajectory.steps)
    end
  end

  defp fingerprint(trajectory) do
    identity =
      {:mnemosyne_trajectory, @fingerprint_version, trajectory.goal,
       Enum.map(trajectory.steps, &{&1.observation, &1.action}), trajectory.metadata}

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
