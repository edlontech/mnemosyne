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

  ### Pipeline
  - `[:mnemosyne, :episode, :append, :start | :stop | :exception]`
  - `[:mnemosyne, :structuring, :extract, :start | :stop | :exception]`
  - `[:mnemosyne, :retrieval, :retrieve, :start | :stop | :exception]`
  - `[:mnemosyne, :reasoning, :reason, :start | :stop | :exception]`

  ### Session
  - `[:mnemosyne, :session, :transition, :start | :stop | :exception]`

  ### Storage / Graph
  - `[:mnemosyne, :graph, :apply_changeset, :start | :stop | :exception]`
  - `[:mnemosyne, :storage, :persist, :start | :stop | :exception]`
  - `[:mnemosyne, :storage, :load, :start | :stop | :exception]`
  """

  @prefix [:mnemosyne]

  @events [
    @prefix ++ [:llm, :chat],
    @prefix ++ [:llm, :chat_structured],
    @prefix ++ [:embedding, :embed],
    @prefix ++ [:embedding, :embed_batch],
    @prefix ++ [:episode, :append],
    @prefix ++ [:structuring, :extract],
    @prefix ++ [:retrieval, :retrieve],
    @prefix ++ [:reasoning, :reason],
    @prefix ++ [:session, :transition],
    @prefix ++ [:graph, :apply_changeset],
    @prefix ++ [:storage, :persist],
    @prefix ++ [:storage, :load]
  ]

  @doc "Returns all event prefixes emitted by Mnemosyne."
  @spec events() :: [[atom()]]
  def events, do: @events

  @doc """
  Wraps a function in a telemetry span.

  The `suffix` is appended to `[:mnemosyne]` to form the event prefix.
  The `fun` must return `{result, extra_measurements}` where
  `extra_measurements` is a map merged into the `:stop` event.
  """
  @spec span([atom()], map(), (-> {term(), map()})) :: term()
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
      {result, extra} = fun.()
      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        event_prefix ++ [:stop],
        Map.merge(extra, %{monotonic_time: System.monotonic_time(), duration: duration}),
        metadata
      )

      result
    rescue
      e ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          event_prefix ++ [:exception],
          %{monotonic_time: System.monotonic_time(), duration: duration},
          Map.merge(metadata, %{kind: :error, reason: e, stacktrace: __STACKTRACE__})
        )

        reraise e, __STACKTRACE__
    end
  end
end
