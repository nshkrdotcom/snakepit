defmodule Snakepit.Telemetry.Span do
  @moduledoc """
  Telemetry span helpers for wrapping operations.

  Provides convenient helpers for emitting start/stop/exception
  telemetry events around function calls.

  ## Usage

      # Automatic span with function
      result = Snakepit.Telemetry.Span.span(
        [:snakepit, :my_operation],
        %{pool: :default},
        fn -> do_operation() end
      )

      # Manual span management
      span_ref = Snakepit.Telemetry.Span.start_span([:snakepit, :operation], %{})
      # ... do work ...
      Snakepit.Telemetry.Span.end_span(span_ref)
  """

  @type event :: [atom()]
  @type metadata :: map()
  @type span_ref :: %{
          event: event(),
          start_time: integer(),
          metadata: metadata()
        }

  @doc """
  Executes a function wrapped in telemetry span events.

  Emits `event ++ [:start]` before the function runs,
  and `event ++ [:stop]` after it completes successfully.
  If the function raises, throws, or exits, emits `event ++ [:exception]`.

  ## Examples

      Span.span([:myapp, :operation], %{user_id: 123}, fn ->
        perform_operation()
      end)
  """
  @spec span(event(), metadata(), (-> result)) :: result when result: any()
  def span(event, metadata, fun) when is_function(fun, 0) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      event ++ [:start],
      %{system_time: System.system_time()},
      metadata
    )

    try do
      result = fun.()

      :telemetry.execute(
        event ++ [:stop],
        %{duration: System.monotonic_time() - start_time},
        metadata
      )

      result
    rescue
      e ->
        :telemetry.execute(
          event ++ [:exception],
          %{duration: System.monotonic_time() - start_time},
          Map.merge(metadata, %{kind: :error, reason: e, stacktrace: __STACKTRACE__})
        )

        reraise e, __STACKTRACE__
    catch
      kind, reason ->
        :telemetry.execute(
          event ++ [:exception],
          %{duration: System.monotonic_time() - start_time},
          Map.merge(metadata, %{kind: kind, reason: reason, stacktrace: __STACKTRACE__})
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @doc """
  Starts a telemetry span.

  Returns a span reference that should be passed to `end_span/1` or `end_span/2`.

  Emits `event ++ [:start]` immediately.

  ## Examples

      span_ref = Span.start_span([:myapp, :operation], %{user_id: 123})
      # ... do work ...
      Span.end_span(span_ref)
  """
  @spec start_span(event(), metadata()) :: span_ref()
  def start_span(event, metadata \\ %{}) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      event ++ [:start],
      %{system_time: System.system_time()},
      metadata
    )

    %{
      event: event,
      start_time: start_time,
      metadata: metadata
    }
  end

  @doc """
  Ends a telemetry span.

  Emits `event ++ [:stop]` with the duration measurement.

  ## Examples

      span_ref = Span.start_span([:myapp, :operation], %{})
      # ... do work ...
      Span.end_span(span_ref)
  """
  @spec end_span(span_ref()) :: :ok
  def end_span(span_ref) do
    end_span(span_ref, %{})
  end

  @doc """
  Ends a telemetry span with additional metadata.

  Merges the additional metadata with the original span metadata
  before emitting the stop event.

  ## Examples

      span_ref = Span.start_span([:myapp, :operation], %{})
      result = do_work()
      Span.end_span(span_ref, %{result: result, items_processed: 100})
  """
  @spec end_span(span_ref(), metadata()) :: :ok
  def end_span(span_ref, additional_metadata) do
    duration = System.monotonic_time() - span_ref.start_time
    metadata = Map.merge(span_ref.metadata, additional_metadata)

    :telemetry.execute(
      span_ref.event ++ [:stop],
      %{duration: duration},
      metadata
    )

    :ok
  end

  @doc """
  Ends a span with an exception.

  Use this when you catch an exception but want to emit the
  exception telemetry event before re-raising or handling it.

  ## Examples

      span_ref = Span.start_span([:myapp, :operation], %{})
      try do
        do_risky_work()
      rescue
        e ->
          Span.end_span_exception(span_ref, :error, e, __STACKTRACE__)
          handle_error(e)
      end
  """
  @spec end_span_exception(span_ref(), :error | :exit | :throw, term(), Exception.stacktrace()) ::
          :ok
  def end_span_exception(span_ref, kind, reason, stacktrace) do
    duration = System.monotonic_time() - span_ref.start_time

    metadata =
      Map.merge(span_ref.metadata, %{
        kind: kind,
        reason: reason,
        stacktrace: stacktrace
      })

    :telemetry.execute(
      span_ref.event ++ [:exception],
      %{duration: duration},
      metadata
    )

    :ok
  end
end
