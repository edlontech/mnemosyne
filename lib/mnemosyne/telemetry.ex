defmodule Mnemosyne.Telemetry do
  @moduledoc """
  Telemetry event catalog and instrumentation helpers for Mnemosyne.

  All events are prefixed with `[:mnemosyne]` and follow the
  `[:mnemosyne, resource, action, :start | :stop | :exception]` convention.

  ## Events

  ### LLM Adapter
  - `[:mnemosyne, :llm, :chat, :start | :stop | :exception]`
  - `[:mnemosyne, :llm, :chat_structured, :start | :stop | :exception]`

  ### Embedding Adapter
  - `[:mnemosyne, :embedding, :embed, :start | :stop | :exception]`
  - `[:mnemosyne, :embedding, :embed_batch, :start | :stop | :exception]`

  ### Model Calls
  - `[:mnemosyne, :model, :call, :start | :stop | :exception]`

  ### Pipeline
  - `[:mnemosyne, :episode, :append, :start | :stop | :exception]`
  - `[:mnemosyne, :structuring, :extract, :start | :stop | :exception]`
  - `[:mnemosyne, :structuring, :extract_trajectory, :start | :stop | :exception]`
  - `[:mnemosyne, :retrieval, :retrieve, :start | :stop | :exception]`
  - `[:mnemosyne, :retrieval, :hop_control, :start | :stop | :exception]`
  - `[:mnemosyne, :retrieval, :hop_refinement, :start | :stop | :exception]`
  - `[:mnemosyne, :reasoning, :reason, :start | :stop | :exception]`
  - `[:mnemosyne, :tag_deduplicator, :deduplicate, :start | :stop | :exception]`

  ### Ingestion
  - `[:mnemosyne, :ingestion, :ingest, :start | :stop | :exception]`
    - Metadata: `repo_id`, `source_id`
    - Stop measurements: `node_count` on success

  ### Maintenance
  - `[:mnemosyne, :decay, :prune, :start | :stop | :exception]`
  - `[:mnemosyne, :consolidator, :consolidate, :start | :stop | :exception]`
  - `[:mnemosyne, :intent_merger, :merge, :start | :stop | :exception]`
  - `[:mnemosyne, :episodic_validation, :validate, :start | :stop | :exception]`
  - `[:mnemosyne, :graph_repair, :repair, :start | :stop | :exception]`

  ### Repository Lifecycle
  - `[:mnemosyne, :repo, :open, :start | :stop | :exception]`
  - `[:mnemosyne, :repo, :close, :start | :stop | :exception]`

  ### Queue
  - `[:mnemosyne, :memory_store, :queue]` — emitted on every queue state change
    - Measurements: `write_queue_size`, `write_active`, `maintenance_active`, `pending_recalls`
    - Metadata: `repo_id`, `event` (`:enqueue`, `:dispatch`, `:maintenance_start`, `:maintenance_complete`)

  ### Storage / Graph
  - `[:mnemosyne, :graph, :apply_changeset, :start | :stop | :exception]`
  """

  @prefix [:mnemosyne]

  @events [
    @prefix ++ [:llm, :chat],
    @prefix ++ [:llm, :chat_structured],
    @prefix ++ [:embedding, :embed],
    @prefix ++ [:embedding, :embed_batch],
    @prefix ++ [:model, :call],
    @prefix ++ [:episode, :append],
    @prefix ++ [:structuring, :extract],
    @prefix ++ [:structuring, :extract_trajectory],
    @prefix ++ [:retrieval, :retrieve],
    @prefix ++ [:retrieval, :hop_control],
    @prefix ++ [:retrieval, :hop_refinement],
    @prefix ++ [:reasoning, :reason],
    @prefix ++ [:tag_deduplicator, :deduplicate],
    @prefix ++ [:decay, :prune],
    @prefix ++ [:consolidator, :consolidate],
    @prefix ++ [:intent_merger, :merge],
    @prefix ++ [:episodic_validation, :validate],
    @prefix ++ [:graph_repair, :repair],
    @prefix ++ [:ingestion, :ingest],
    @prefix ++ [:repo, :open],
    @prefix ++ [:repo, :close],
    @prefix ++ [:memory_store, :queue],
    @prefix ++ [:graph, :apply_changeset]
  ]

  @doc "Returns all event prefixes emitted by Mnemosyne."
  @spec events() :: [[atom()]]
  def events, do: @events

  @doc """
  Wraps a function in a telemetry span.

  The `suffix` is appended to `[:mnemosyne]` to form the event prefix.
  The `fun` must return `{result, extra_measurements}` or
  `{result, extra_measurements, extra_metadata}`. Measurements and terminal
  metadata are merged into the `:stop` event.
  """
  @spec span([atom()], map(), (-> {term(), map()} | {term(), map(), map()})) :: term()
  def span(suffix, metadata, fun)
      when is_list(suffix) and is_map(metadata) and is_function(fun, 0) do
    event_prefix = @prefix ++ suffix
    start_time = System.monotonic_time()

    :telemetry.execute(
      event_prefix ++ [:start],
      %{monotonic_time: start_time, system_time: System.system_time()},
      metadata
    )

    try do
      {result, measurements, terminal_metadata} = terminal_result(fun.())
      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        event_prefix ++ [:stop],
        Map.merge(measurements, %{monotonic_time: System.monotonic_time(), duration: duration}),
        Map.merge(metadata, terminal_metadata)
      )

      result
    rescue
      exception ->
        stacktrace = __STACKTRACE__
        emit_exception(event_prefix, start_time, metadata, :error, exception, stacktrace)
        reraise exception, stacktrace
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        emit_exception(event_prefix, start_time, metadata, kind, reason, stacktrace)
        :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp terminal_result({result, measurements}), do: {result, measurements, %{}}

  defp terminal_result({result, measurements, metadata}), do: {result, measurements, metadata}

  defp emit_exception(event_prefix, start_time, metadata, exception_kind, reason, stacktrace) do
    duration = System.monotonic_time() - start_time

    exception_metadata = %{
      exception_kind: exception_kind,
      reason: reason,
      stacktrace: stacktrace,
      status: :exception
    }

    exception_metadata =
      if Map.has_key?(metadata, :kind) do
        exception_metadata
      else
        Map.put(exception_metadata, :kind, exception_kind)
      end

    :telemetry.execute(
      event_prefix ++ [:exception],
      %{monotonic_time: System.monotonic_time(), duration: duration},
      Map.merge(metadata, exception_metadata)
    )
  end
end
