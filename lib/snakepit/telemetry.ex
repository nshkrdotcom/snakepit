defmodule Snakepit.Telemetry do
  @moduledoc """
  Telemetry event definitions for Snakepit.
  """

  require Logger

  @doc """
  Lists all telemetry events used by Snakepit.
  """
  def events do
    session_events() ++ variable_events() ++ program_events()
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
  Variable-related telemetry events.
  """
  def variable_events do
    [
      # Variable operations
      [:snakepit, :session_store, :variable, :registered],
      [:snakepit, :session_store, :variable, :get],
      [:snakepit, :session_store, :variable, :updated],
      [:snakepit, :session_store, :variable, :deleted],

      # Batch operations
      [:snakepit, :session_store, :variables, :batch_get],
      [:snakepit, :session_store, :variables, :batch_update],

      # Validation
      [:snakepit, :session_store, :variable, :validation_failed],
      [:snakepit, :session_store, :variable, :constraint_violation]
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
  Attaches default handlers for all events.
  """
  def attach_handlers do
    attach_session_handlers()
    attach_variable_handlers()
    attach_program_handlers()
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
  Attaches default handlers for variable events.
  """
  def attach_variable_handlers do
    :telemetry.attach_many(
      "snakepit-variable-logger",
      variable_events(),
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

  # Event handlers

  defp handle_event(
         [:snakepit, :session_store, :variable, :registered],
         _measurements,
         metadata,
         _
       ) do
    Logger.info("Variable registered: type=#{metadata.type} session=#{metadata.session_id}")
  end

  defp handle_event([:snakepit, :session_store, :variable, :updated], measurements, metadata, _) do
    Logger.debug("Variable updated: type=#{metadata.type} version=#{measurements.version}")
  end

  defp handle_event([:snakepit, :session_store, :variable, :get], _measurements, metadata, _) do
    cache_status = if metadata[:cache_hit], do: "hit", else: "miss"
    Logger.debug("Variable retrieved: session=#{metadata.session_id} cache=#{cache_status}")
  end

  defp handle_event([:snakepit, :session_store, :variable, :deleted], _measurements, metadata, _) do
    Logger.info("Variable deleted: session=#{metadata.session_id}")
  end

  defp handle_event(
         [:snakepit, :session_store, :variables, :batch_get],
         measurements,
         metadata,
         _
       ) do
    Logger.debug("Batch get: count=#{measurements.count} session=#{metadata.session_id}")
  end

  defp handle_event(
         [:snakepit, :session_store, :variables, :batch_update],
         measurements,
         metadata,
         _
       ) do
    Logger.debug("Batch update: count=#{measurements.count} session=#{metadata.session_id}")
  end

  defp handle_event(
         [:snakepit, :session_store, :variable, :validation_failed],
         _measurements,
         metadata,
         _
       ) do
    Logger.warning("Variable validation failed: type=#{metadata.type} reason=#{metadata.reason}")
  end

  defp handle_event(
         [:snakepit, :session_store, :variable, :constraint_violation],
         _measurements,
         metadata,
         _
       ) do
    Logger.warning(
      "Variable constraint violation: type=#{metadata.type} constraint=#{metadata.constraint}"
    )
  end

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

  # Catch-all handler for any unhandled events
  defp handle_event(event, measurements, metadata, _) do
    Logger.debug(
      "Telemetry event: #{inspect(event)} measurements=#{inspect(measurements)} metadata=#{inspect(metadata)}"
    )
  end
end
