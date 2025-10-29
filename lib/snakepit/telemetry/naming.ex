defmodule Snakepit.Telemetry.Naming do
  @moduledoc """
  Event catalog and naming validation for Snakepit telemetry.

  This module ensures atom safety by maintaining a curated catalog of all
  valid telemetry events and measurement keys. Python-originated events
  must pass through this module to prevent arbitrary atom creation.
  """

  # Layer 1: Infrastructure Events (Elixir-originated)
  @pool_events [
    :initialized,
    :status,
    :queue_enqueued,
    :queue_dequeued,
    :queue_timeout,
    :worker_spawn_started,
    :worker_spawned,
    :worker_spawn_failed,
    :worker_terminated,
    :worker_restarted
  ]

  @session_events [
    :created,
    :destroyed,
    :affinity_assigned,
    :affinity_broken
  ]

  # Layer 2: Python Execution Events (Python-originated, folded by Elixir)
  @python_events [
    :call_start,
    :call_stop,
    :call_exception,
    :memory_sampled,
    :cpu_sampled,
    :gc_completed,
    :error_occurred
  ]

  # Layer 3: gRPC Bridge Events (Elixir-originated)
  @grpc_events [
    :call_start,
    :call_stop,
    :call_exception,
    :stream_opened,
    :stream_message,
    :stream_closed,
    :connection_established,
    :connection_lost,
    :connection_reconnected
  ]

  # Valid measurement keys (atom-safe)
  @measurement_keys [
    :duration,
    :system_time,
    :queue_depth,
    :queue_time,
    :available_workers,
    :busy_workers,
    :total_workers,
    :worker_count,
    :lifetime,
    :total_commands,
    :command_count,
    :downtime,
    :restart_count,
    :retry_count,
    :request_size,
    :response_size,
    :message_size,
    :sequence_number,
    :message_count,
    :network_time,
    :uptime,
    :call_count,
    :affinity_duration,
    :commands_with_affinity,
    :rss_bytes,
    :vms_bytes,
    :cpu_percent,
    :collected,
    :generation,
    :latency_ms,
    :count,
    :python_pid
  ]

  @doc """
  Convert Python event parts to a valid Elixir telemetry event name.

  Returns `{:ok, event_name}` if the parts map to a known event,
  `{:error, reason}` otherwise.

  ## Examples

      iex> Snakepit.Telemetry.Naming.from_parts(["python", "call", "start"])
      {:ok, [:snakepit, :python, :call, :start]}

      iex> Snakepit.Telemetry.Naming.from_parts(["unknown", "event"])
      {:error, :unknown_event}
  """
  def from_parts(parts) when is_list(parts) do
    case parts do
      # Python events
      ["python", "call", "start"] ->
        {:ok, [:snakepit, :python, :call, :start]}

      ["python", "call", "stop"] ->
        {:ok, [:snakepit, :python, :call, :stop]}

      ["python", "call", "exception"] ->
        {:ok, [:snakepit, :python, :call, :exception]}

      ["python", "memory", "sampled"] ->
        {:ok, [:snakepit, :python, :memory, :sampled]}

      ["python", "cpu", "sampled"] ->
        {:ok, [:snakepit, :python, :cpu, :sampled]}

      ["python", "gc", "completed"] ->
        {:ok, [:snakepit, :python, :gc, :completed]}

      ["python", "error", "occurred"] ->
        {:ok, [:snakepit, :python, :error, :occurred]}

      # Alternative format with dots
      ["tool", "execution", action] when action in ["start", "stop", "exception"] ->
        {:ok, [:snakepit, :python, :tool, :execution, String.to_existing_atom(action)]}

      ["tool", "result_size"] ->
        {:ok, [:snakepit, :python, :tool, :result_size]}

      _ ->
        {:error, :unknown_event}
    end
  rescue
    ArgumentError -> {:error, :invalid_atom}
  end

  @doc """
  Validate a measurement key and convert to atom if it's in the allowlist.

  ## Examples

      iex> Snakepit.Telemetry.Naming.measurement_key("duration")
      {:ok, :duration}

      iex> Snakepit.Telemetry.Naming.measurement_key("unknown_key")
      {:error, :unknown_measurement_key}
  """
  def measurement_key(key) when is_binary(key) do
    atom_key = String.to_existing_atom(key)

    if atom_key in @measurement_keys do
      {:ok, atom_key}
    else
      {:error, :unknown_measurement_key}
    end
  rescue
    ArgumentError -> {:error, :invalid_atom}
  end

  def measurement_key(key) when is_atom(key) do
    if key in @measurement_keys do
      {:ok, key}
    else
      {:error, :unknown_measurement_key}
    end
  end

  @doc """
  Get all valid pool events.
  """
  def pool_events, do: @pool_events

  @doc """
  Get all valid session events.
  """
  def session_events, do: @session_events

  @doc """
  Get all valid Python events.
  """
  def python_events, do: @python_events

  @doc """
  Get all valid gRPC events.
  """
  def grpc_events, do: @grpc_events

  @doc """
  Get all valid measurement keys.
  """
  def measurement_keys, do: @measurement_keys

  @doc """
  Build an event name from components.

  ## Examples

      iex> Snakepit.Telemetry.Naming.event(:pool, :worker, :spawned)
      [:snakepit, :pool, :worker, :spawned]
  """
  def event(component, resource, action) do
    [:snakepit, component, resource, action]
  end

  @doc """
  Build a pool event name.
  """
  def pool_event(action) when action in @pool_events do
    case action do
      :initialized -> [:snakepit, :pool, :initialized]
      :status -> [:snakepit, :pool, :status]
      :queue_enqueued -> [:snakepit, :pool, :queue, :enqueued]
      :queue_dequeued -> [:snakepit, :pool, :queue, :dequeued]
      :queue_timeout -> [:snakepit, :pool, :queue, :timeout]
      :worker_spawn_started -> [:snakepit, :pool, :worker, :spawn_started]
      :worker_spawned -> [:snakepit, :pool, :worker, :spawned]
      :worker_spawn_failed -> [:snakepit, :pool, :worker, :spawn_failed]
      :worker_terminated -> [:snakepit, :pool, :worker, :terminated]
      :worker_restarted -> [:snakepit, :pool, :worker, :restarted]
    end
  end

  @doc """
  Build a session event name.
  """
  def session_event(action) when action in @session_events do
    case action do
      :created -> [:snakepit, :session, :created]
      :destroyed -> [:snakepit, :session, :destroyed]
      :affinity_assigned -> [:snakepit, :session, :affinity, :assigned]
      :affinity_broken -> [:snakepit, :session, :affinity, :broken]
    end
  end

  @doc """
  Build a Python event name.
  """
  def python_event(action) when action in @python_events do
    case action do
      :call_start -> [:snakepit, :python, :call, :start]
      :call_stop -> [:snakepit, :python, :call, :stop]
      :call_exception -> [:snakepit, :python, :call, :exception]
      :memory_sampled -> [:snakepit, :python, :memory, :sampled]
      :cpu_sampled -> [:snakepit, :python, :cpu, :sampled]
      :gc_completed -> [:snakepit, :python, :gc, :completed]
      :error_occurred -> [:snakepit, :python, :error, :occurred]
    end
  end

  @doc """
  Build a gRPC event name.
  """
  def grpc_event(resource, action) when action in @grpc_events do
    [:snakepit, :grpc, resource, action]
  end
end
