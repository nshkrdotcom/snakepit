defmodule Snakepit.Telemetry do
  @moduledoc """
  Telemetry event definitions for Snakepit.

  This module provides:
  - Complete event catalog (Layer 1: Infrastructure, Layer 2: Python, Layer 3: gRPC)
  - Event handler management
  - Integration with the distributed telemetry system

  See `Snakepit.Telemetry.Naming` for event name validation and atom safety.
  See `Snakepit.Telemetry.GrpcStream` for Python telemetry folding.

  ## Usage

      # Attach handlers to specific events
      :telemetry.attach(
        "my-handler",
        [:snakepit, :python, :call, :stop],
        &MyApp.Telemetry.handle_python_call/4,
        nil
      )

      # Emit a pool event
      :telemetry.execute(
        [:snakepit, :pool, :worker, :spawned],
        %{duration: 1000, system_time: System.system_time()},
        %{node: node(), worker_id: "worker_1", pool_name: :default}
      )
  """

  require Logger
  alias Snakepit.Logger, as: SLog

  @doc """
  Lists all telemetry events used by Snakepit.
  """
  def events do
    session_events() ++
      program_events() ++
      heartbeat_events() ++
      pool_events() ++ python_events() ++ grpc_events() ++ runtime_events()
  end

  ## Layer 0: Session Store & Heartbeat (Legacy)

  @doc """
  Session-related telemetry events (session store).
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
  Program-related telemetry events (session store).
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

  ## Layer 1: Infrastructure Events (Pool, Worker, Session)

  @doc """
  Pool and worker lifecycle events.
  """
  def pool_events do
    [
      [:snakepit, :pool, :initialized],
      [:snakepit, :pool, :status],
      [:snakepit, :pool, :queue, :enqueued],
      [:snakepit, :pool, :queue, :dequeued],
      [:snakepit, :pool, :queue, :timeout],
      [:snakepit, :pool, :worker, :spawn_started],
      [:snakepit, :pool, :worker, :spawned],
      [:snakepit, :pool, :worker, :spawn_failed],
      [:snakepit, :pool, :worker, :terminated],
      [:snakepit, :pool, :worker, :restarted],
      [:snakepit, :worker, :recycled],
      [:snakepit, :session, :created],
      [:snakepit, :session, :destroyed],
      [:snakepit, :session, :affinity, :assigned],
      [:snakepit, :session, :affinity, :broken]
    ]
  end

  ## Layer 2: Python Execution Events (Folded from Python)

  @doc """
  Python worker telemetry events (folded back from Python workers).
  """
  def python_events do
    [
      [:snakepit, :python, :call, :start],
      [:snakepit, :python, :call, :stop],
      [:snakepit, :python, :call, :exception],
      [:snakepit, :python, :memory, :sampled],
      [:snakepit, :python, :cpu, :sampled],
      [:snakepit, :python, :gc, :completed],
      [:snakepit, :python, :error, :occurred],
      [:snakepit, :python, :tool, :execution, :start],
      [:snakepit, :python, :tool, :execution, :stop],
      [:snakepit, :python, :tool, :execution, :exception],
      [:snakepit, :python, :tool, :result_size]
    ]
  end

  ## Layer 3: gRPC Bridge Events

  @doc """
  gRPC communication events.
  """
  def grpc_events do
    [
      [:snakepit, :grpc, :call, :start],
      [:snakepit, :grpc, :call, :stop],
      [:snakepit, :grpc, :call, :exception],
      [:snakepit, :grpc, :stream, :opened],
      [:snakepit, :grpc, :stream, :message],
      [:snakepit, :grpc, :stream, :closed],
      [:snakepit, :grpc, :connection, :established],
      [:snakepit, :grpc, :connection, :lost],
      [:snakepit, :grpc, :connection, :reconnected]
    ]
  end

  @doc """
  Runtime enhancement events (zero-copy, crash barrier, exception translation).
  """
  def runtime_events do
    [
      [:snakepit, :zero_copy, :export],
      [:snakepit, :zero_copy, :import],
      [:snakepit, :zero_copy, :fallback],
      [:snakepit, :worker, :crash],
      [:snakepit, :worker, :tainted],
      [:snakepit, :worker, :restarted],
      [:snakepit, :python, :exception, :mapped],
      [:snakepit, :python, :exception, :unmapped]
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
    SLog.info("Session created: #{metadata.session_id}")
  end

  defp handle_event([:snakepit, :session_store, :session, :accessed], _measurements, metadata, _) do
    SLog.debug("Session accessed: #{metadata.session_id}")
  end

  defp handle_event([:snakepit, :session_store, :session, :deleted], _measurements, metadata, _) do
    SLog.info("Session deleted: #{metadata.session_id}")
  end

  defp handle_event([:snakepit, :session_store, :session, :expired], measurements, _metadata, _) do
    SLog.info("Sessions expired: count=#{measurements.count}")
  end

  # Program event handlers
  defp handle_event([:snakepit, :session_store, :program, :stored], _measurements, metadata, _) do
    SLog.debug("Program stored: #{metadata.program_id} in session #{metadata.session_id}")
  end

  defp handle_event([:snakepit, :session_store, :program, :retrieved], _measurements, metadata, _) do
    SLog.debug("Program retrieved: #{metadata.program_id} from session #{metadata.session_id}")
  end

  defp handle_event([:snakepit, :session_store, :program, :deleted], _measurements, metadata, _) do
    SLog.debug("Program deleted: #{metadata.program_id} from session #{metadata.session_id}")
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
    SLog.debug(
      "Telemetry event: #{inspect(event)} measurements=#{inspect(measurements)} metadata=#{inspect(metadata)}"
    )
  end
end
