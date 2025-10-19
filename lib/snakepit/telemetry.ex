defmodule Snakepit.Telemetry do
  @moduledoc """
  Telemetry event definitions for Snakepit.
  """

  require Logger

  @doc """
  Lists all telemetry events used by Snakepit.
  """
  def events do
    session_events() ++ program_events() ++ heartbeat_events()
  end

  @doc """
  Session-related telemetry events.
  """
  def session_events do
    [
      [:snakepit, :session_store, :session, :created],
      [:snakepit, :session_store, :session, :accessed],
      [:snakepit, :session_store, :session, :deleted],
      [:snakepit, :session_store, :session, :expired]
    ]
  end

  @doc """
  Program-related telemetry events.
  """
  def program_events do
    [
      [:snakepit, :session_store, :program, :stored],
      [:snakepit, :session_store, :program, :retrieved],
      [:snakepit, :session_store, :program, :deleted]
    ]
  end

  @doc """
  Heartbeat and monitor telemetry events.
  """
  def heartbeat_events do
    [
      [:snakepit, :heartbeat, :monitor_started],
      [:snakepit, :heartbeat, :monitor_stopped],
      [:snakepit, :heartbeat, :monitor_failure],
      [:snakepit, :heartbeat, :ping_sent],
      [:snakepit, :heartbeat, :pong_received],
      [:snakepit, :heartbeat, :heartbeat_timeout]
    ]
  end

  @doc """
  Attaches default handlers for all events.
  """
  def attach_handlers do
    attach_session_handlers()
    attach_program_handlers()
    attach_heartbeat_handlers()
  end

  @doc """
  Attaches default handlers for session events.
  """
  def attach_session_handlers do
    :telemetry.attach_many(
      "snakepit-session-logger",
      session_events(),
      &handle_event/4,
      nil
    )
  end

  @doc """
  Attaches default handlers for program events.
  """
  def attach_program_handlers do
    :telemetry.attach_many(
      "snakepit-program-logger",
      program_events(),
      &handle_event/4,
      nil
    )
  end

  @doc """
  Attaches default handlers for heartbeat events.
  """
  def attach_heartbeat_handlers do
    :telemetry.attach_many(
      "snakepit-heartbeat-logger",
      heartbeat_events(),
      &handle_event/4,
      nil
    )
  end

  # Event handlers

  # Session event handlers
  defp handle_event([:snakepit, :session_store, :session, :created], _measurements, metadata, _) do
    Logger.info("Session created: #{metadata.session_id}")
  end

  defp handle_event([:snakepit, :session_store, :session, :accessed], _measurements, metadata, _) do
    Logger.debug("Session accessed: #{metadata.session_id}")
  end

  defp handle_event([:snakepit, :session_store, :session, :deleted], _measurements, metadata, _) do
    Logger.info("Session deleted: #{metadata.session_id}")
  end

  defp handle_event([:snakepit, :session_store, :session, :expired], measurements, _metadata, _) do
    Logger.info("Sessions expired: count=#{measurements.count}")
  end

  # Program event handlers
  defp handle_event([:snakepit, :session_store, :program, :stored], _measurements, metadata, _) do
    Logger.debug("Program stored: #{metadata.program_id} in session #{metadata.session_id}")
  end

  defp handle_event([:snakepit, :session_store, :program, :retrieved], _measurements, metadata, _) do
    Logger.debug("Program retrieved: #{metadata.program_id} from session #{metadata.session_id}")
  end

  defp handle_event([:snakepit, :session_store, :program, :deleted], _measurements, metadata, _) do
    Logger.debug("Program deleted: #{metadata.program_id} from session #{metadata.session_id}")
  end

  # Heartbeat events
  defp handle_event([:snakepit, :heartbeat, :monitor_started], _measurements, metadata, _) do
    Logger.debug("Heartbeat monitor started for #{metadata.worker_id}")
  end

  defp handle_event([:snakepit, :heartbeat, :monitor_stopped], _measurements, metadata, _) do
    Logger.debug(
      "Heartbeat monitor stopped for #{metadata.worker_id} reason=#{inspect(metadata.reason)}"
    )
  end

  defp handle_event([:snakepit, :heartbeat, :monitor_failure], _measurements, metadata, _) do
    Logger.warning(
      "Heartbeat monitor triggered failure for #{metadata.worker_id}: #{inspect(metadata.failure_reason)}"
    )
  end

  defp handle_event([:snakepit, :heartbeat, :ping_sent], measurements, metadata, _) do
    Logger.debug("Heartbeat ping sent for #{metadata.worker_id} (count=#{measurements[:count]})")
  end

  defp handle_event([:snakepit, :heartbeat, :pong_received], measurements, metadata, _) do
    Logger.debug(
      "Heartbeat pong received for #{metadata.worker_id} latency=#{measurements[:latency_ms]}ms"
    )
  end

  defp handle_event([:snakepit, :heartbeat, :heartbeat_timeout], measurements, metadata, _) do
    Logger.warning("Heartbeat timeout for #{metadata.worker_id} missed=#{measurements[:count]}")
  end

  # Catch-all handler for any unhandled events
  defp handle_event(event, measurements, metadata, _) do
    Logger.debug(
      "Telemetry event: #{inspect(event)} measurements=#{inspect(measurements)} metadata=#{inspect(metadata)}"
    )
  end
end
