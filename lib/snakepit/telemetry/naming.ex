defmodule Snakepit.Telemetry.Naming do
  @moduledoc """
  Event catalog and naming validation for Snakepit telemetry.

  This module ensures atom safety by maintaining a curated catalog of all
  valid telemetry events and measurement keys. Python-originated events
  must pass through this module to prevent arbitrary atom creation.

  ## Python Event Catalog

  `python_event_catalog/0` lists the event strings emitted by `snakepit_bridge`
  and the measurement keys they are expected to use. When adding a new Python
  telemetry event, update that catalog and the allowlist in
  `snakepit_bridge.telemetry.stream` together so both languages agree on the
  schema.
  """

  # Layer 1: Infrastructure Events (Elixir-originated)
  @pool_events [
    :initialized,
    :init_started,
    :init_complete,
    :status,
    :queue_enqueued,
    :queue_dequeued,
    :queue_timeout,
    :worker_spawn_started,
    :worker_spawned,
    :worker_ready,
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

  @python_event_catalog [
    %{
      name: "python.call.start",
      event: [:snakepit, :python, :call, :start],
      measurements: [:count]
    },
    %{
      name: "python.call.stop",
      event: [:snakepit, :python, :call, :stop],
      measurements: [:duration, :count]
    },
    %{
      name: "python.call.exception",
      event: [:snakepit, :python, :call, :exception],
      measurements: [:count]
    },
    %{
      name: "python.memory.sampled",
      event: [:snakepit, :python, :memory, :sampled],
      measurements: [:rss_bytes, :vms_bytes]
    },
    %{
      name: "python.cpu.sampled",
      event: [:snakepit, :python, :cpu, :sampled],
      measurements: [:cpu_percent]
    },
    %{
      name: "python.gc.completed",
      event: [:snakepit, :python, :gc, :completed],
      measurements: [:count, :generation]
    },
    %{
      name: "python.error.occurred",
      event: [:snakepit, :python, :error, :occurred],
      measurements: [:count]
    },
    %{
      name: "tool.execution.start",
      event: [:snakepit, :python, :tool, :execution, :start],
      measurements: [:count]
    },
    %{
      name: "tool.execution.stop",
      event: [:snakepit, :python, :tool, :execution, :stop],
      measurements: [:duration, :count]
    },
    %{
      name: "tool.execution.exception",
      event: [:snakepit, :python, :tool, :execution, :exception],
      measurements: [:count]
    },
    %{
      name: "tool.result_size",
      event: [:snakepit, :python, :tool, :result_size],
      measurements: [:message_size]
    }
  ]

  # Valid measurement keys (atom-safe)
  @measurement_keys [
    :duration,
    :duration_ms,
    :bytes,
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
  def from_parts(["python", "call", "start"]) do
    {:ok, [:snakepit, :python, :call, :start]}
  end

  def from_parts(["python", "call", "stop"]) do
    {:ok, [:snakepit, :python, :call, :stop]}
  end

  def from_parts(["python", "call", "exception"]) do
    {:ok, [:snakepit, :python, :call, :exception]}
  end

  def from_parts(["python", "memory", "sampled"]) do
    {:ok, [:snakepit, :python, :memory, :sampled]}
  end

  def from_parts(["python", "cpu", "sampled"]) do
    {:ok, [:snakepit, :python, :cpu, :sampled]}
  end

  def from_parts(["python", "gc", "completed"]) do
    {:ok, [:snakepit, :python, :gc, :completed]}
  end

  def from_parts(["python", "error", "occurred"]) do
    {:ok, [:snakepit, :python, :error, :occurred]}
  end

  def from_parts(["tool", "execution", action]) when action in ["start", "stop", "exception"] do
    {:ok, [:snakepit, :python, :tool, :execution, String.to_existing_atom(action)]}
  rescue
    ArgumentError -> {:error, :invalid_atom}
  end

  def from_parts(["tool", "result_size"]) do
    {:ok, [:snakepit, :python, :tool, :result_size]}
  end

  def from_parts(parts) when is_list(parts) do
    {:error, :unknown_event}
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
  Return the catalog describing Python event names, their telemetry atoms, and expected measurements.
  """
  def python_event_catalog, do: @python_event_catalog

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
  def pool_event(:initialized), do: [:snakepit, :pool, :initialized]
  def pool_event(:init_started), do: [:snakepit, :pool, :init_started]
  def pool_event(:init_complete), do: [:snakepit, :pool, :init_complete]
  def pool_event(:status), do: [:snakepit, :pool, :status]
  def pool_event(:queue_enqueued), do: [:snakepit, :pool, :queue, :enqueued]
  def pool_event(:queue_dequeued), do: [:snakepit, :pool, :queue, :dequeued]
  def pool_event(:queue_timeout), do: [:snakepit, :pool, :queue, :timeout]
  def pool_event(:worker_spawn_started), do: [:snakepit, :pool, :worker, :spawn_started]
  def pool_event(:worker_spawned), do: [:snakepit, :pool, :worker, :spawned]
  def pool_event(:worker_ready), do: [:snakepit, :pool, :worker_ready]
  def pool_event(:worker_spawn_failed), do: [:snakepit, :pool, :worker, :spawn_failed]
  def pool_event(:worker_terminated), do: [:snakepit, :pool, :worker, :terminated]
  def pool_event(:worker_restarted), do: [:snakepit, :pool, :worker, :restarted]

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
