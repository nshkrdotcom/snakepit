defmodule Snakepit.Telemetry do
  @moduledoc """
  Cognitive-ready telemetry infrastructure for Snakepit.
  
  Provides telemetry events for core infrastructure operations with
  hooks for adapter-specific enhancement and future cognitive features.
  """

  require Logger

  @doc """
  Lists all core telemetry events used by Snakepit infrastructure.
  """
  def events do
    pool_events() ++ worker_events() ++ adapter_events() ++ cognitive_events()
  end

  @doc """
  Pool-related telemetry events.
  """
  def pool_events do
    [
      [:snakepit, :pool, :started],
      [:snakepit, :pool, :stopped],
      [:snakepit, :pool, :worker, :added],
      [:snakepit, :pool, :worker, :removed],
      [:snakepit, :pool, :execution, :start],
      [:snakepit, :pool, :execution, :stop],
      [:snakepit, :pool, :execution, :error]
    ]
  end

  @doc """
  Worker-related telemetry events.
  """
  def worker_events do
    [
      [:snakepit, :worker, :started],
      [:snakepit, :worker, :stopped],
      [:snakepit, :worker, :command, :start],
      [:snakepit, :worker, :command, :stop],
      [:snakepit, :worker, :command, :error],
      [:snakepit, :worker, :stream, :start],
      [:snakepit, :worker, :stream, :stop]
    ]
  end

  @doc """
  Adapter-related telemetry events.
  """
  def adapter_events do
    [
      [:snakepit, :adapter, :initialized],
      [:snakepit, :adapter, :terminated],
      [:snakepit, :adapter, :execute, :start],
      [:snakepit, :adapter, :execute, :stop],
      [:snakepit, :adapter, :execute, :error],
      [:snakepit, :adapter, :performance_metrics]
    ]
  end

  @doc """
  Cognitive-ready telemetry events for future enhancement.
  """
  def cognitive_events do
    [
      [:snakepit, :cognitive, :session, :created],
      [:snakepit, :cognitive, :session, :accessed],
      [:snakepit, :cognitive, :session, :destroyed],
      [:snakepit, :cognitive, :learning, :pattern_detected],
      [:snakepit, :cognitive, :optimization, :applied]
    ]
  end

  @doc """
  Attaches default handlers for all events.
  """
  def attach_handlers do
    attach_pool_handlers()
    attach_worker_handlers()
    attach_adapter_handlers()
    attach_cognitive_handlers()
  end

  @doc """
  Attaches default handlers for pool events.
  """
  def attach_pool_handlers do
    :telemetry.attach_many(
      "snakepit-pool-logger",
      pool_events(),
      &handle_event/4,
      nil
    )
  end

  @doc """
  Attaches default handlers for worker events.
  """
  def attach_worker_handlers do
    :telemetry.attach_many(
      "snakepit-worker-logger",
      worker_events(),
      &handle_event/4,
      nil
    )
  end

  @doc """
  Attaches default handlers for adapter events.
  """
  def attach_adapter_handlers do
    :telemetry.attach_many(
      "snakepit-adapter-logger",
      adapter_events(),
      &handle_event/4,
      nil
    )
  end

  @doc """
  Attaches default handlers for cognitive events.
  """
  def attach_cognitive_handlers do
    :telemetry.attach_many(
      "snakepit-cognitive-logger",
      cognitive_events(),
      &handle_event/4,
      nil
    )
  end

  # Event handlers

  # Pool event handlers
  defp handle_event([:snakepit, :pool, :started], _measurements, metadata, _) do
    Logger.info("Pool started with #{metadata.worker_count} workers")
  end

  defp handle_event([:snakepit, :pool, :stopped], _measurements, metadata, _) do
    Logger.info("Pool stopped: #{metadata.reason}")
  end

  defp handle_event([:snakepit, :pool, :worker, :added], _measurements, metadata, _) do
    Logger.debug("Worker added to pool: #{metadata.worker_id}")
  end

  defp handle_event([:snakepit, :pool, :worker, :removed], _measurements, metadata, _) do
    Logger.debug("Worker removed from pool: #{metadata.worker_id}")
  end

  defp handle_event([:snakepit, :pool, :execution, :start], _measurements, metadata, _) do
    Logger.debug("Pool execution started: #{metadata.command}")
  end

  defp handle_event([:snakepit, :pool, :execution, :stop], measurements, metadata, _) do
    Logger.debug("Pool execution completed: #{metadata.command} (#{measurements.duration}ms)")
  end

  defp handle_event([:snakepit, :pool, :execution, :error], _measurements, metadata, _) do
    Logger.warning("Pool execution error: #{metadata.command} - #{metadata.error}")
  end

  # Worker event handlers
  defp handle_event([:snakepit, :worker, :started], _measurements, metadata, _) do
    Logger.debug("Worker started: #{metadata.worker_id}")
  end

  defp handle_event([:snakepit, :worker, :stopped], _measurements, metadata, _) do
    Logger.debug("Worker stopped: #{metadata.worker_id}")
  end

  defp handle_event([:snakepit, :worker, :command, :start], _measurements, metadata, _) do
    Logger.debug("Worker command started: #{metadata.worker_id} -> #{metadata.command}")
  end

  defp handle_event([:snakepit, :worker, :command, :stop], measurements, metadata, _) do
    Logger.debug("Worker command completed: #{metadata.worker_id} (#{measurements.duration}ms)")
  end

  defp handle_event([:snakepit, :worker, :command, :error], _measurements, metadata, _) do
    Logger.warning("Worker command error: #{metadata.worker_id} - #{metadata.error}")
  end

  defp handle_event([:snakepit, :worker, :stream, :start], _measurements, metadata, _) do
    Logger.debug("Worker stream started: #{metadata.worker_id}")
  end

  defp handle_event([:snakepit, :worker, :stream, :stop], measurements, metadata, _) do
    Logger.debug("Worker stream completed: #{metadata.worker_id} (#{measurements.duration}ms)")
  end

  # Adapter event handlers
  defp handle_event([:snakepit, :adapter, :initialized], _measurements, metadata, _) do
    Logger.info("Adapter initialized: #{metadata.adapter_module}")
  end

  defp handle_event([:snakepit, :adapter, :terminated], _measurements, metadata, _) do
    Logger.info("Adapter terminated: #{metadata.adapter_module}")
  end

  defp handle_event([:snakepit, :adapter, :execute, :start], _measurements, metadata, _) do
    Logger.debug("Adapter execution started: #{metadata.command}")
  end

  defp handle_event([:snakepit, :adapter, :execute, :stop], measurements, metadata, _) do
    Logger.debug("Adapter execution completed: #{metadata.command} (#{measurements.duration}ms)")
  end

  defp handle_event([:snakepit, :adapter, :execute, :error], _measurements, metadata, _) do
    Logger.warning("Adapter execution error: #{metadata.command} - #{metadata.error}")
  end

  defp handle_event([:snakepit, :adapter, :performance_metrics], measurements, metadata, _) do
    Logger.debug("Adapter performance metrics: #{inspect(measurements)} #{inspect(metadata)}")
  end

  # Cognitive event handlers (placeholders for future enhancement)
  defp handle_event([:snakepit, :cognitive, :session, :created], _measurements, metadata, _) do
    Logger.debug("Cognitive session created: #{metadata.session_id}")
  end

  defp handle_event([:snakepit, :cognitive, :session, :accessed], _measurements, metadata, _) do
    Logger.debug("Cognitive session accessed: #{metadata.session_id}")
  end

  defp handle_event([:snakepit, :cognitive, :session, :destroyed], _measurements, metadata, _) do
    Logger.debug("Cognitive session destroyed: #{metadata.session_id}")
  end

  defp handle_event([:snakepit, :cognitive, :learning, :pattern_detected], _measurements, metadata, _) do
    Logger.info("Learning pattern detected: #{metadata.pattern_type}")
  end

  defp handle_event([:snakepit, :cognitive, :optimization, :applied], _measurements, metadata, _) do
    Logger.info("Cognitive optimization applied: #{metadata.optimization_type}")
  end

  # Catch-all handler for any unhandled events
  defp handle_event(event, measurements, metadata, _) do
    Logger.debug(
      "Telemetry event: #{inspect(event)} measurements=#{inspect(measurements)} metadata=#{inspect(metadata)}"
    )
  end

  @doc """
  Emit a telemetry event with measurements and metadata.
  
  This is a convenience function for emitting telemetry events from
  infrastructure code with proper error handling.
  """
  def emit(event, measurements \\ %{}, metadata \\ %{}) do
    :telemetry.execute(event, measurements, metadata)
  rescue
    error ->
      Logger.debug("Failed to emit telemetry event #{inspect(event)}: #{inspect(error)}")
  end
end
