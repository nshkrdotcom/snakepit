# Telemetry and Observability

## Overview

This document specifies Snakepit's telemetry and observability system, providing comprehensive instrumentation for debugging, performance analysis, and production monitoring.

## Problem Statement

ML workloads are notoriously hard to debug:
- "Why is this inference slow?" (CPU/GPU/IO bound?)
- "Where did my GPU memory go?"
- "What's the queue depth in the worker pool?"
- "Which Python library is the bottleneck?"

Without proper observability, teams spend hours guessing.

## Design Goals

1. **Zero-config basics**: Useful metrics out of the box
2. **Low overhead**: <1% performance impact when enabled
3. **OpenTelemetry compatible**: Standard tracing/metrics format
4. **ML-specific metrics**: Tensor shapes, GPU memory, batch sizes

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    TELEMETRY ARCHITECTURE                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Application Code                                                │
│       │                                                          │
│       ▼                                                          │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │               Snakepit.Telemetry                            ││
│  │  ├── Event definitions                                      ││
│  │  ├── Span management                                        ││
│  │  └── Context propagation                                    ││
│  └─────────────────────────────────────────────────────────────┘│
│       │                                                          │
│       ▼                                                          │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │               :telemetry (Erlang)                           ││
│  │  ├── Event dispatch                                         ││
│  │  └── Handler registration                                   ││
│  └─────────────────────────────────────────────────────────────┘│
│       │                                                          │
│       ├──────────────────┬──────────────────┬──────────────────┐ │
│       ▼                  ▼                  ▼                  │ │
│  ┌──────────┐      ┌──────────┐      ┌──────────┐             │ │
│  │  Logger  │      │Prometheus│      │  OpenTel │             │ │
│  └──────────┘      └──────────┘      └──────────┘             │ │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Telemetry Events

### Core Events

```elixir
defmodule Snakepit.Telemetry do
  @moduledoc """
  Telemetry event definitions and helpers.
  """

  # ============================================================
  # EXECUTION EVENTS
  # ============================================================

  @doc """
  Emitted when a Python call starts.

  - `[:snakepit, :call, :start]`
  - Measurements: `%{system_time: integer()}`
  - Metadata: `%{
      operation: String.t(),
      library: String.t(),
      function: String.t(),
      worker_id: reference(),
      device: term()
    }`
  """
  def call_start(operation, metadata) do
    :telemetry.execute(
      [:snakepit, :call, :start],
      %{system_time: System.system_time()},
      Map.merge(metadata, %{operation: operation})
    )
  end

  @doc """
  Emitted when a Python call completes.

  - `[:snakepit, :call, :stop]`
  - Measurements: `%{
      duration: integer(),      # nanoseconds
      queue_time: integer(),    # time waiting for worker
      serialize_time: integer(),# encoding args
      python_time: integer(),   # actual Python execution
      deserialize_time: integer()
    }`
  - Metadata: `%{
      operation: String.t(),
      library: String.t(),
      function: String.t(),
      result: :ok | :error,
      error_type: atom() | nil
    }`
  """
  def call_stop(start_time, metadata, timings) do
    duration = System.monotonic_time() - start_time

    measurements = Map.merge(timings, %{duration: duration})

    :telemetry.execute(
      [:snakepit, :call, :stop],
      measurements,
      metadata
    )
  end

  @doc """
  Emitted when a Python call fails.

  - `[:snakepit, :call, :exception]`
  - Measurements: `%{duration: integer()}`
  - Metadata: `%{
      operation: String.t(),
      kind: :error | :exit | :throw,
      reason: term(),
      stacktrace: list()
    }`
  """
  def call_exception(start_time, metadata, kind, reason, stacktrace) do
    :telemetry.execute(
      [:snakepit, :call, :exception],
      %{duration: System.monotonic_time() - start_time},
      Map.merge(metadata, %{
        kind: kind,
        reason: reason,
        stacktrace: stacktrace
      })
    )
  end

  # ============================================================
  # WORKER POOL EVENTS
  # ============================================================

  @doc """
  Worker checked out from pool.

  - `[:snakepit, :pool, :checkout]`
  - Measurements: `%{queue_time: integer()}`
  - Metadata: `%{pool: atom(), worker_id: reference()}`
  """
  def pool_checkout(queue_time, pool, worker_id) do
    :telemetry.execute(
      [:snakepit, :pool, :checkout],
      %{queue_time: queue_time},
      %{pool: pool, worker_id: worker_id}
    )
  end

  @doc """
  Worker returned to pool.

  - `[:snakepit, :pool, :checkin]`
  - Measurements: `%{busy_time: integer()}`
  - Metadata: `%{pool: atom(), worker_id: reference()}`
  """
  def pool_checkin(busy_time, pool, worker_id) do
    :telemetry.execute(
      [:snakepit, :pool, :checkin],
      %{busy_time: busy_time},
      %{pool: pool, worker_id: worker_id}
    )
  end

  @doc """
  Pool size changed.

  - `[:snakepit, :pool, :size]`
  - Measurements: `%{size: integer(), idle: integer(), busy: integer()}`
  - Metadata: `%{pool: atom()}`
  """
  def pool_size(pool, size, idle, busy) do
    :telemetry.execute(
      [:snakepit, :pool, :size],
      %{size: size, idle: idle, busy: busy},
      %{pool: pool}
    )
  end

  # ============================================================
  # MEMORY EVENTS
  # ============================================================

  @doc """
  Memory allocation event (for zero-copy tensors).

  - `[:snakepit, :memory, :allocate]`
  - Measurements: `%{bytes: integer()}`
  - Metadata: `%{type: :cpu | :gpu, device: term()}`
  """
  def memory_allocate(bytes, type, device \\ nil) do
    :telemetry.execute(
      [:snakepit, :memory, :allocate],
      %{bytes: bytes},
      %{type: type, device: device}
    )
  end

  @doc """
  Memory release event.

  - `[:snakepit, :memory, :release]`
  - Measurements: `%{bytes: integer()}`
  - Metadata: `%{type: :cpu | :gpu, device: term()}`
  """
  def memory_release(bytes, type, device \\ nil) do
    :telemetry.execute(
      [:snakepit, :memory, :release],
      %{bytes: bytes},
      %{type: type, device: device}
    )
  end

  @doc """
  GPU memory snapshot.

  - `[:snakepit, :memory, :gpu]`
  - Measurements: `%{
      allocated_mb: integer(),
      reserved_mb: integer(),
      free_mb: integer(),
      total_mb: integer()
    }`
  - Metadata: `%{device: {:cuda, integer()}}`
  """
  def gpu_memory(device, allocated, reserved, free, total) do
    :telemetry.execute(
      [:snakepit, :memory, :gpu],
      %{
        allocated_mb: allocated,
        reserved_mb: reserved,
        free_mb: free,
        total_mb: total
      },
      %{device: device}
    )
  end

  # ============================================================
  # SERIALIZATION EVENTS
  # ============================================================

  @doc """
  Serialization timing.

  - `[:snakepit, :serialize, :stop]`
  - Measurements: `%{duration: integer(), bytes: integer()}`
  - Metadata: `%{direction: :encode | :decode, format: :json | :arrow}`
  """
  def serialize_stop(duration, bytes, direction, format) do
    :telemetry.execute(
      [:snakepit, :serialize, :stop],
      %{duration: duration, bytes: bytes},
      %{direction: direction, format: format}
    )
  end
end
```

### ML-Specific Events

```elixir
defmodule Snakepit.Telemetry.ML do
  @moduledoc """
  ML-specific telemetry events.
  """

  @doc """
  Tensor operation metadata.

  - `[:snakepit, :ml, :tensor_op]`
  - Measurements: `%{
      duration: integer(),
      input_elements: integer(),
      output_elements: integer()
    }`
  - Metadata: `%{
      op: atom(),
      input_shapes: [list()],
      output_shape: list(),
      dtype: atom(),
      device: term()
    }`
  """
  def tensor_op(duration, op, input_shapes, output_shape, dtype, device) do
    input_elements = input_shapes |> Enum.map(&Enum.product/1) |> Enum.sum()
    output_elements = Enum.product(output_shape)

    :telemetry.execute(
      [:snakepit, :ml, :tensor_op],
      %{
        duration: duration,
        input_elements: input_elements,
        output_elements: output_elements
      },
      %{
        op: op,
        input_shapes: input_shapes,
        output_shape: output_shape,
        dtype: dtype,
        device: device
      }
    )
  end

  @doc """
  Model inference timing.

  - `[:snakepit, :ml, :inference]`
  - Measurements: `%{
      duration: integer(),
      batch_size: integer(),
      tokens_per_second: float() | nil
    }`
  - Metadata: `%{
      model: String.t(),
      device: term()
    }`
  """
  def inference(duration, batch_size, model, device, tokens \\ nil) do
    tps = if tokens, do: tokens / (duration / 1_000_000_000), else: nil

    :telemetry.execute(
      [:snakepit, :ml, :inference],
      %{
        duration: duration,
        batch_size: batch_size,
        tokens_per_second: tps
      },
      %{model: model, device: device}
    )
  end

  @doc """
  Training step timing.

  - `[:snakepit, :ml, :train_step]`
  - Measurements: `%{
      duration: integer(),
      loss: float(),
      learning_rate: float()
    }`
  - Metadata: `%{
      epoch: integer(),
      step: integer(),
      model: String.t()
    }`
  """
  def train_step(duration, loss, lr, epoch, step, model) do
    :telemetry.execute(
      [:snakepit, :ml, :train_step],
      %{
        duration: duration,
        loss: loss,
        learning_rate: lr
      },
      %{epoch: epoch, step: step, model: model}
    )
  end
end
```

## Span/Trace Support

```elixir
defmodule Snakepit.Telemetry.Span do
  @moduledoc """
  OpenTelemetry-compatible span management.
  """

  @doc """
  Wraps a function call in a telemetry span.
  """
  defmacro span(name, metadata \\ %{}, do: block) do
    quote do
      start_time = System.monotonic_time()

      :telemetry.execute(
        [:snakepit | unquote(name)] ++ [:start],
        %{system_time: System.system_time()},
        unquote(metadata)
      )

      try do
        result = unquote(block)

        :telemetry.execute(
          [:snakepit | unquote(name)] ++ [:stop],
          %{duration: System.monotonic_time() - start_time},
          Map.put(unquote(metadata), :result, :ok)
        )

        result
      rescue
        e ->
          :telemetry.execute(
            [:snakepit | unquote(name)] ++ [:exception],
            %{duration: System.monotonic_time() - start_time},
            Map.merge(unquote(metadata), %{
              kind: :error,
              reason: e,
              stacktrace: __STACKTRACE__
            })
          )

          reraise e, __STACKTRACE__
      end
    end
  end
end
```

## Default Handlers

### Logger Handler

```elixir
defmodule Snakepit.Telemetry.Handlers.Logger do
  @moduledoc """
  Logs telemetry events at configurable levels.
  """

  require Logger

  def attach do
    events = [
      [:snakepit, :call, :stop],
      [:snakepit, :call, :exception],
      [:snakepit, :worker, :crash],
      [:snakepit, :circuit_breaker, :open],
      [:snakepit, :health, :alert]
    ]

    :telemetry.attach_many(
      "snakepit-logger",
      events,
      &handle_event/4,
      %{}
    )
  end

  def handle_event([:snakepit, :call, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    if duration_ms > slow_threshold() do
      Logger.warning(
        "Slow Python call: #{metadata.library}.#{metadata.function} took #{duration_ms}ms"
      )
    else
      Logger.debug(
        "Python call: #{metadata.library}.#{metadata.function} (#{duration_ms}ms)"
      )
    end
  end

  def handle_event([:snakepit, :call, :exception], _measurements, metadata, _config) do
    Logger.error(
      "Python call failed: #{metadata.operation} - #{inspect(metadata.reason)}"
    )
  end

  def handle_event([:snakepit, :worker, :crash], _measurements, metadata, _config) do
    Logger.error(
      "Python worker crashed: type=#{metadata.type}, device=#{inspect(metadata.device)}"
    )
  end

  def handle_event([:snakepit, :circuit_breaker, :open], measurements, metadata, _config) do
    Logger.warning(
      "Circuit breaker opened for device #{inspect(metadata.device)} " <>
      "after #{measurements.failure_count} failures"
    )
  end

  def handle_event([:snakepit, :health, :alert], measurements, metadata, _config) do
    Logger.error(
      "Health alert: #{metadata.alert_type} - #{measurements.crash_count} recent crashes"
    )
  end

  defp slow_threshold do
    Application.get_env(:snakepit, :telemetry, [])
    |> Keyword.get(:slow_call_threshold_ms, 1000)
  end
end
```

### Metrics Handler (Prometheus-compatible)

```elixir
defmodule Snakepit.Telemetry.Handlers.Metrics do
  @moduledoc """
  Collects metrics for Prometheus/StatsD export.
  """

  def metrics do
    [
      # Call metrics
      Telemetry.Metrics.counter("snakepit.call.total",
        tags: [:library, :function, :result]
      ),
      Telemetry.Metrics.distribution("snakepit.call.duration",
        tags: [:library, :function],
        unit: {:native, :millisecond},
        reporter_options: [buckets: [10, 50, 100, 250, 500, 1000, 2500, 5000, 10000]]
      ),
      Telemetry.Metrics.distribution("snakepit.call.queue_time",
        tags: [:library],
        unit: {:native, :millisecond}
      ),

      # Pool metrics
      Telemetry.Metrics.last_value("snakepit.pool.size",
        tags: [:pool]
      ),
      Telemetry.Metrics.last_value("snakepit.pool.idle",
        tags: [:pool]
      ),
      Telemetry.Metrics.last_value("snakepit.pool.busy",
        tags: [:pool]
      ),

      # Memory metrics
      Telemetry.Metrics.sum("snakepit.memory.allocated_bytes",
        tags: [:type, :device]
      ),
      Telemetry.Metrics.last_value("snakepit.memory.gpu.allocated_mb",
        tags: [:device]
      ),
      Telemetry.Metrics.last_value("snakepit.memory.gpu.free_mb",
        tags: [:device]
      ),

      # Error metrics
      Telemetry.Metrics.counter("snakepit.call.exceptions",
        tags: [:library, :error_type]
      ),
      Telemetry.Metrics.counter("snakepit.worker.crashes",
        tags: [:type, :device]
      ),

      # ML metrics
      Telemetry.Metrics.distribution("snakepit.ml.inference.duration",
        tags: [:model, :device],
        unit: {:native, :millisecond}
      ),
      Telemetry.Metrics.last_value("snakepit.ml.inference.tokens_per_second",
        tags: [:model, :device]
      )
    ]
  end
end
```

## GPU Memory Profiler

```elixir
defmodule Snakepit.Telemetry.GPUProfiler do
  @moduledoc """
  Profiles GPU memory usage over time.
  """

  use GenServer

  @default_interval_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)

    if Snakepit.Hardware.capabilities().cuda do
      :timer.send_interval(interval, :sample)
    end

    {:ok, %{samples: [], max_samples: 1000}}
  end

  @impl GenServer
  def handle_info(:sample, state) do
    samples = sample_gpu_memory()

    # Emit telemetry for each GPU
    Enum.each(samples, fn {device, stats} ->
      Snakepit.Telemetry.gpu_memory(
        device,
        stats.allocated_mb,
        stats.reserved_mb,
        stats.free_mb,
        stats.total_mb
      )
    end)

    # Store for history
    new_samples = [{DateTime.utc_now(), samples} | Enum.take(state.samples, state.max_samples - 1)]

    {:noreply, %{state | samples: new_samples}}
  end

  @doc """
  Returns GPU memory history.
  """
  def history(limit \\ 100) do
    GenServer.call(__MODULE__, {:history, limit})
  end

  @impl GenServer
  def handle_call({:history, limit}, _from, state) do
    {:reply, Enum.take(state.samples, limit), state}
  end

  defp sample_gpu_memory do
    script = """
    import torch
    import json
    result = {}
    for i in range(torch.cuda.device_count()):
        allocated = torch.cuda.memory_allocated(i) / 1024 / 1024
        reserved = torch.cuda.memory_reserved(i) / 1024 / 1024
        total = torch.cuda.get_device_properties(i).total_memory / 1024 / 1024
        free = total - reserved
        result[i] = {
            'allocated_mb': int(allocated),
            'reserved_mb': int(reserved),
            'free_mb': int(free),
            'total_mb': int(total)
        }
    print(json.dumps(result))
    """

    case System.cmd("python3", ["-c", script], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.trim()
        |> Jason.decode!()
        |> Enum.map(fn {id, stats} ->
          {{:cuda, String.to_integer(id)}, atomize_keys(stats)}
        end)

      _ ->
        []
    end
  end

  defp atomize_keys(map) do
    Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)
  end
end
```

## Repro Script Generator

When errors occur, generate a standalone Python script for reproduction:

```elixir
defmodule Snakepit.Telemetry.ReproGenerator do
  @moduledoc """
  Generates reproduction scripts from failed calls.
  """

  @spec generate(map(), map()) :: String.t()
  def generate(payload, error) do
    """
    #!/usr/bin/env python3
    \"\"\"
    Reproduction script generated by Snakepit.
    Error: #{inspect(error.message)}
    Generated: #{DateTime.utc_now() |> DateTime.to_iso8601()}
    \"\"\"

    import sys
    import json

    # Payload that caused the error
    payload = #{Jason.encode!(payload, pretty: true)}

    # Reproduce the call
    def reproduce():
        library = payload['library']
        function = payload['function']
        args = payload['args']
        kwargs = payload.get('kwargs', {})

        # Import the library
        import importlib
        module = importlib.import_module(payload['python_module'])

        # Get the function
        func = getattr(module, function)

        # Call it
        try:
            result = func(*args, **kwargs)
            print(f"Success: {result}")
            return result
        except Exception as e:
            print(f"Error: {type(e).__name__}: {e}")
            import traceback
            traceback.print_exc()
            sys.exit(1)

    if __name__ == '__main__':
        reproduce()
    """
  end

  @doc """
  Writes repro script to file.
  """
  @spec save(map(), map(), Path.t()) :: :ok | {:error, term()}
  def save(payload, error, path \\ nil) do
    path = path || "snakepit_repro_#{System.system_time(:second)}.py"
    script = generate(payload, error)
    File.write(path, script)
  end
end
```

## LiveDashboard Integration

```elixir
defmodule Snakepit.Telemetry.LiveDashboard do
  @moduledoc """
  Phoenix LiveDashboard page for Snakepit.
  """

  use Phoenix.LiveDashboard.PageBuilder

  @impl true
  def menu_link(_, _) do
    {:ok, "Snakepit"}
  end

  @impl true
  def render_page(_assigns) do
    # Returns LiveDashboard page components
    {
      :ok,
      [
        # Worker pool stats
        card(title: "Worker Pool") do
          pool_stats()
        end,

        # GPU memory
        card(title: "GPU Memory") do
          gpu_memory_chart()
        end,

        # Recent calls
        table(
          title: "Recent Calls",
          columns: [:time, :library, :function, :duration_ms, :result],
          rows: recent_calls()
        ),

        # Error log
        table(
          title: "Recent Errors",
          columns: [:time, :library, :error_type, :message],
          rows: recent_errors()
        )
      ]
    }
  end

  defp pool_stats do
    stats = Snakepit.WorkerPool.stats()
    """
    Workers: #{stats.total} (#{stats.idle} idle, #{stats.busy} busy)
    Queue depth: #{stats.queue_depth}
    """
  end

  defp gpu_memory_chart do
    history = Snakepit.Telemetry.GPUProfiler.history(60)
    # Return chart data
    history
  end

  defp recent_calls do
    # Get from ETS or ring buffer
    []
  end

  defp recent_errors do
    # Get from error log
    []
  end
end
```

## Configuration

```elixir
config :snakepit, :telemetry,
  enabled: true,

  # Handlers
  handlers: [
    :logger,           # Log events
    :metrics           # Prometheus metrics
  ],

  # Thresholds
  slow_call_threshold_ms: 1000,

  # GPU profiling
  gpu_profiler_enabled: true,
  gpu_profiler_interval_ms: 5000,

  # Repro scripts
  repro_on_error: true,
  repro_directory: "tmp/snakepit_repro",

  # Sampling
  sample_rate: 1.0  # 1.0 = 100%, 0.1 = 10%
```

## Setup

```elixir
defmodule MyApp.Application do
  def start(_type, _args) do
    # Attach Snakepit telemetry handlers
    Snakepit.Telemetry.Handlers.Logger.attach()

    # If using TelemetryMetricsPrometheus
    TelemetryMetricsPrometheus.Core.attach(
      Snakepit.Telemetry.Handlers.Metrics.metrics()
    )

    children = [
      # Your other children...
      Snakepit.Telemetry.GPUProfiler
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

## Implementation Phases

### Phase 1: Core Events (Week 1)
- [ ] Define all event schemas
- [ ] Instrument execute path
- [ ] Instrument worker pool

### Phase 2: Handlers (Week 2)
- [ ] Logger handler
- [ ] Metrics definitions
- [ ] Prometheus integration

### Phase 3: ML-Specific (Week 3)
- [ ] GPU memory profiler
- [ ] Tensor operation events
- [ ] Repro script generator

### Phase 4: Dashboard (Week 4)
- [ ] LiveDashboard page
- [ ] Historical data storage
- [ ] Real-time updates

## SnakeBridge Integration

SnakeBridge integrates with Snakepit telemetry by:

1. **Adding compilation events** for generation timing
2. **Forwarding runtime telemetry** from generated wrappers
3. **Including telemetry in generated docs**

See: `snakebridge/docs/20251227/world-class-ml/05-telemetry-integration.md`
