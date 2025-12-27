# Crash Barrier Supervision

## Overview

This document specifies Snakepit's crash barrier supervision system, treating Python workers as "disposable hazardous materials" that can crash without affecting the BEAM VM.

## Problem Statement

ML libraries are unstable:
- CUDA out-of-memory errors
- C-extension segfaults (NumPy, SciPy, PyTorch)
- GPU driver crashes
- Memory corruption from native code

Current Python interop libraries often crash the entire BEAM VM or leave zombie processes.

## Design Goals

1. **Isolation**: Python crashes never crash the BEAM
2. **Recovery**: Automatic worker replacement after crashes
3. **Transparency**: Idempotent operations retry automatically
4. **Visibility**: Crash patterns are logged and surfaced

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     ELIXIR SUPERVISION TREE                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Snakepit.Supervisor (rest_for_one)                             │
│  ├── Snakepit.Registry                                          │
│  ├── Snakepit.CircuitBreaker                                    │
│  ├── Snakepit.HealthMonitor                                     │
│  └── Snakepit.WorkerPool.Supervisor (one_for_one)               │
│      ├── Snakepit.WorkerPool (DynamicSupervisor)                │
│      │   ├── Worker 1 (Port-based, isolated)                    │
│      │   ├── Worker 2 (Port-based, isolated)                    │
│      │   └── Worker N (Port-based, isolated)                    │
│      └── Snakepit.WorkerPool.Manager                            │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ OS Process Boundary
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     PYTHON PROCESSES                             │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐       ┌─────────────┐        │
│  │  Python 1   │  │  Python 2   │  ...  │  Python N   │        │
│  │  (Worker)   │  │  (Worker)   │       │  (Worker)   │        │
│  └─────────────┘  └─────────────┘       └─────────────┘        │
│                                                                  │
│  Each process is completely isolated                            │
│  Crashes are caught by BEAM Port monitoring                     │
└─────────────────────────────────────────────────────────────────┘
```

## Worker Isolation

### Port-Based Execution

Workers run as OS processes via Erlang Ports, providing complete memory isolation:

```elixir
defmodule Snakepit.Worker do
  use GenServer

  @type state :: %{
    port: port() | nil,
    status: :idle | :busy | :crashed | :draining,
    crash_count: non_neg_integer(),
    last_crash: DateTime.t() | nil,
    current_request: reference() | nil,
    device_affinity: {:cuda, non_neg_integer()} | :cpu | nil
  }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      port: nil,
      status: :idle,
      crash_count: 0,
      last_crash: nil,
      current_request: nil,
      device_affinity: Keyword.get(opts, :device_affinity)
    }

    {:ok, state, {:continue, :start_port}}
  end

  @impl GenServer
  def handle_continue(:start_port, state) do
    port = open_python_port(state.device_affinity)
    {:noreply, %{state | port: port, status: :idle}}
  end

  @impl GenServer
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    # Port crashed - handle gracefully
    crash_info = classify_exit_status(status)

    Logger.warning("Python worker crashed: #{inspect(crash_info)}")

    new_state = %{state |
      port: nil,
      status: :crashed,
      crash_count: state.crash_count + 1,
      last_crash: DateTime.utc_now()
    }

    # Notify pending request
    if state.current_request do
      send_crash_response(state.current_request, crash_info)
    end

    # Report to health monitor
    Snakepit.HealthMonitor.report_crash(self(), crash_info)

    # Attempt restart after cooldown
    Process.send_after(self(), :restart, restart_delay(new_state))

    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(:restart, state) do
    if should_restart?(state) do
      port = open_python_port(state.device_affinity)
      {:noreply, %{state | port: port, status: :idle}}
    else
      # Too many crashes - let supervisor handle
      {:stop, :too_many_crashes, state}
    end
  end

  defp open_python_port(device_affinity) do
    env = build_env(device_affinity)

    Port.open({:spawn_executable, python_executable()}, [
      :binary,
      :exit_status,
      :use_stdio,
      {:env, env},
      {:args, ["-m", "snakepit.worker"]}
    ])
  end

  defp build_env(nil), do: []
  defp build_env(:cpu), do: [{'CUDA_VISIBLE_DEVICES', ''}]
  defp build_env({:cuda, id}), do: [{'CUDA_VISIBLE_DEVICES', to_charlist("#{id}")}]

  defp classify_exit_status(status) do
    cond do
      status == 0 -> :normal
      status == 1 -> :python_error
      status == 137 -> :killed  # SIGKILL
      status == 139 -> :segfault  # SIGSEGV
      status == 134 -> :abort  # SIGABRT
      status == 136 -> :floating_point_error  # SIGFPE
      true -> {:unknown, status}
    end
  end

  defp restart_delay(%{crash_count: n}) do
    # Exponential backoff: 100ms, 200ms, 400ms, 800ms, max 5000ms
    min(100 * :math.pow(2, n - 1) |> trunc(), 5000)
  end

  defp should_restart?(%{crash_count: count}) when count > 10, do: false
  defp should_restart?(_), do: true
end
```

## Circuit Breaker

Prevents cascading failures when Python workers are consistently failing:

```elixir
defmodule Snakepit.CircuitBreaker do
  use GenServer

  @type state :: %{
    status: :closed | :open | :half_open,
    failure_count: non_neg_integer(),
    success_count: non_neg_integer(),
    last_failure: DateTime.t() | nil,
    open_until: DateTime.t() | nil,
    per_device: %{optional({:cuda, non_neg_integer()}) => circuit_state()}
  }

  @type circuit_state :: %{
    status: :closed | :open | :half_open,
    failure_count: non_neg_integer(),
    success_count: non_neg_integer()
  }

  # Configuration
  @failure_threshold 5
  @success_threshold 3
  @open_duration_ms 30_000
  @half_open_requests 3

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks if a request should be allowed through.
  """
  @spec allow?(keyword()) :: :ok | {:error, :circuit_open}
  def allow?(opts \\ []) do
    device = Keyword.get(opts, :device)
    GenServer.call(__MODULE__, {:allow?, device})
  end

  @doc """
  Records a successful request.
  """
  @spec record_success(keyword()) :: :ok
  def record_success(opts \\ []) do
    device = Keyword.get(opts, :device)
    GenServer.cast(__MODULE__, {:success, device})
  end

  @doc """
  Records a failed request.
  """
  @spec record_failure(keyword()) :: :ok
  def record_failure(opts \\ []) do
    device = Keyword.get(opts, :device)
    GenServer.cast(__MODULE__, {:failure, device})
  end

  @impl GenServer
  def init(_opts) do
    state = %{
      status: :closed,
      failure_count: 0,
      success_count: 0,
      last_failure: nil,
      open_until: nil,
      per_device: %{}
    }
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:allow?, device}, _from, state) do
    circuit = get_circuit(state, device)

    case circuit.status do
      :closed ->
        {:reply, :ok, state}

      :open ->
        if DateTime.compare(DateTime.utc_now(), circuit.open_until) == :gt do
          # Transition to half-open
          new_state = update_circuit(state, device, %{circuit | status: :half_open, success_count: 0})
          {:reply, :ok, new_state}
        else
          {:reply, {:error, :circuit_open}, state}
        end

      :half_open ->
        {:reply, :ok, state}
    end
  end

  @impl GenServer
  def handle_cast({:success, device}, state) do
    circuit = get_circuit(state, device)

    new_circuit = case circuit.status do
      :half_open ->
        new_success = circuit.success_count + 1
        if new_success >= @success_threshold do
          %{circuit | status: :closed, failure_count: 0, success_count: 0}
        else
          %{circuit | success_count: new_success}
        end

      _ ->
        %{circuit | failure_count: max(0, circuit.failure_count - 1)}
    end

    {:noreply, update_circuit(state, device, new_circuit)}
  end

  @impl GenServer
  def handle_cast({:failure, device}, state) do
    circuit = get_circuit(state, device)
    new_failure_count = circuit.failure_count + 1

    new_circuit = if new_failure_count >= @failure_threshold do
      Logger.warning("Circuit breaker opened for device #{inspect(device)}")

      :telemetry.execute(
        [:snakepit, :circuit_breaker, :open],
        %{failure_count: new_failure_count},
        %{device: device}
      )

      %{circuit |
        status: :open,
        failure_count: new_failure_count,
        open_until: DateTime.add(DateTime.utc_now(), @open_duration_ms, :millisecond)
      }
    else
      %{circuit | failure_count: new_failure_count}
    end

    {:noreply, update_circuit(state, device, new_circuit)}
  end

  defp get_circuit(state, nil), do: state
  defp get_circuit(state, device) do
    Map.get(state.per_device, device, %{
      status: :closed,
      failure_count: 0,
      success_count: 0,
      open_until: nil
    })
  end

  defp update_circuit(state, nil, circuit) do
    Map.merge(state, circuit)
  end
  defp update_circuit(state, device, circuit) do
    %{state | per_device: Map.put(state.per_device, device, circuit)}
  end
end
```

## Health Monitor

Tracks worker health and crash patterns:

```elixir
defmodule Snakepit.HealthMonitor do
  use GenServer

  @type crash_info :: %{
    worker: pid(),
    type: atom(),
    timestamp: DateTime.t(),
    device: term() | nil,
    request_info: map() | nil
  }

  @type state :: %{
    crashes: [crash_info()],
    workers: %{pid() => worker_stats()},
    device_health: %{term() => device_stats()}
  }

  @type worker_stats :: %{
    started_at: DateTime.t(),
    requests_handled: non_neg_integer(),
    crashes: non_neg_integer(),
    last_active: DateTime.t()
  }

  @type device_stats :: %{
    crashes: non_neg_integer(),
    oom_count: non_neg_integer(),
    last_healthy: DateTime.t() | nil,
    status: :healthy | :degraded | :unhealthy
  }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Reports a worker crash.
  """
  @spec report_crash(pid(), term()) :: :ok
  def report_crash(worker, crash_type) do
    GenServer.cast(__MODULE__, {:crash, worker, crash_type})
  end

  @doc """
  Gets current health status.
  """
  @spec health_status() :: map()
  def health_status do
    GenServer.call(__MODULE__, :health_status)
  end

  @doc """
  Gets crash history for analysis.
  """
  @spec crash_history(keyword()) :: [crash_info()]
  def crash_history(opts \\ []) do
    GenServer.call(__MODULE__, {:crash_history, opts})
  end

  @impl GenServer
  def init(_opts) do
    # Periodic cleanup of old crash data
    :timer.send_interval(60_000, :cleanup)

    state = %{
      crashes: [],
      workers: %{},
      device_health: %{}
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:crash, worker, crash_type}, state) do
    crash_info = %{
      worker: worker,
      type: crash_type,
      timestamp: DateTime.utc_now(),
      device: get_worker_device(worker),
      request_info: nil
    }

    # Emit telemetry
    :telemetry.execute(
      [:snakepit, :worker, :crash],
      %{count: 1},
      %{type: crash_type, device: crash_info.device}
    )

    # Update state
    new_crashes = [crash_info | Enum.take(state.crashes, 999)]
    new_device_health = update_device_health(state.device_health, crash_info)

    new_state = %{state |
      crashes: new_crashes,
      device_health: new_device_health
    }

    # Check for patterns that need alerting
    check_crash_patterns(new_state)

    {:noreply, new_state}
  end

  @impl GenServer
  def handle_call(:health_status, _from, state) do
    status = %{
      overall: overall_health(state),
      workers: %{
        total: map_size(state.workers),
        healthy: count_healthy_workers(state.workers)
      },
      devices: state.device_health,
      recent_crashes: length(recent_crashes(state.crashes, 300))  # Last 5 min
    }

    {:reply, status, state}
  end

  @impl GenServer
  def handle_call({:crash_history, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)
    device = Keyword.get(opts, :device)

    crashes = state.crashes
    |> filter_by_device(device)
    |> Enum.take(limit)

    {:reply, crashes, state}
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    # Remove crashes older than 1 hour
    cutoff = DateTime.add(DateTime.utc_now(), -3600, :second)

    new_crashes = Enum.filter(state.crashes, fn crash ->
      DateTime.compare(crash.timestamp, cutoff) == :gt
    end)

    {:noreply, %{state | crashes: new_crashes}}
  end

  defp update_device_health(device_health, %{device: nil}), do: device_health
  defp update_device_health(device_health, crash_info) do
    device = crash_info.device
    current = Map.get(device_health, device, %{
      crashes: 0,
      oom_count: 0,
      last_healthy: nil,
      status: :healthy
    })

    updated = %{current |
      crashes: current.crashes + 1,
      oom_count: current.oom_count + (if crash_info.type == :oom, do: 1, else: 0),
      status: compute_device_status(current.crashes + 1)
    }

    Map.put(device_health, device, updated)
  end

  defp compute_device_status(crashes) when crashes > 10, do: :unhealthy
  defp compute_device_status(crashes) when crashes > 5, do: :degraded
  defp compute_device_status(_), do: :healthy

  defp overall_health(state) do
    device_statuses = Map.values(state.device_health) |> Enum.map(& &1.status)
    recent = recent_crashes(state.crashes, 60)

    cond do
      length(recent) > 10 -> :critical
      :unhealthy in device_statuses -> :unhealthy
      :degraded in device_statuses -> :degraded
      true -> :healthy
    end
  end

  defp recent_crashes(crashes, seconds) do
    cutoff = DateTime.add(DateTime.utc_now(), -seconds, :second)
    Enum.filter(crashes, fn crash ->
      DateTime.compare(crash.timestamp, cutoff) == :gt
    end)
  end

  defp filter_by_device(crashes, nil), do: crashes
  defp filter_by_device(crashes, device) do
    Enum.filter(crashes, fn crash -> crash.device == device end)
  end

  defp get_worker_device(_worker), do: nil  # TODO: Lookup from registry
  defp count_healthy_workers(workers), do: map_size(workers)  # TODO: Implement

  defp check_crash_patterns(state) do
    recent = recent_crashes(state.crashes, 60)

    # Alert on high crash rate
    if length(recent) > 5 do
      Logger.error("High crash rate detected: #{length(recent)} crashes in last minute")

      :telemetry.execute(
        [:snakepit, :health, :alert],
        %{crash_count: length(recent)},
        %{alert_type: :high_crash_rate}
      )
    end

    # Alert on repeated segfaults
    segfaults = Enum.count(recent, fn c -> c.type == :segfault end)
    if segfaults > 2 do
      Logger.error("Multiple segfaults detected: #{segfaults} in last minute")
    end
  end
end
```

## Transparent Retry

Automatically retry idempotent operations:

```elixir
defmodule Snakepit.RetryPolicy do
  @moduledoc """
  Handles automatic retry of failed operations.
  """

  @type retry_opts :: [
    max_attempts: pos_integer(),
    backoff: :exponential | :linear | :constant,
    initial_delay_ms: pos_integer(),
    max_delay_ms: pos_integer(),
    retryable_errors: [atom()]
  ]

  @default_opts [
    max_attempts: 3,
    backoff: :exponential,
    initial_delay_ms: 100,
    max_delay_ms: 5000,
    retryable_errors: [:worker_crash, :timeout, :segfault]
  ]

  @doc """
  Executes a function with automatic retry on failure.
  """
  @spec with_retry((() -> result), retry_opts()) :: result when result: term()
  def with_retry(fun, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)
    do_retry(fun, opts, 1)
  end

  defp do_retry(fun, opts, attempt) do
    case fun.() do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} = error ->
        if should_retry?(reason, opts) and attempt < opts[:max_attempts] do
          delay = compute_delay(attempt, opts)

          Logger.debug("Retrying after #{delay}ms (attempt #{attempt + 1}/#{opts[:max_attempts]})")

          :timer.sleep(delay)
          do_retry(fun, opts, attempt + 1)
        else
          error
        end
    end
  end

  defp should_retry?(reason, opts) do
    error_type = classify_error(reason)
    error_type in opts[:retryable_errors]
  end

  defp classify_error(%{type: type}), do: type
  defp classify_error({type, _}), do: type
  defp classify_error(type) when is_atom(type), do: type
  defp classify_error(_), do: :unknown

  defp compute_delay(attempt, opts) do
    base = opts[:initial_delay_ms]
    max = opts[:max_delay_ms]

    delay = case opts[:backoff] do
      :exponential -> base * :math.pow(2, attempt - 1) |> trunc()
      :linear -> base * attempt
      :constant -> base
    end

    # Add jitter (0-25%)
    jitter = :rand.uniform() * 0.25 * delay |> trunc()

    min(delay + jitter, max)
  end
end
```

## Request Execution with Barriers

```elixir
defmodule Snakepit.Executor do
  @moduledoc """
  Executes requests with full crash barrier protection.
  """

  alias Snakepit.{CircuitBreaker, RetryPolicy, WorkerPool, HealthMonitor}

  @spec execute(String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def execute(operation, payload, opts \\ []) do
    device = Keyword.get(opts, :device)
    idempotent = Keyword.get(opts, :idempotent, false)

    # Check circuit breaker
    with :ok <- CircuitBreaker.allow?(device: device) do
      execute_fn = fn ->
        do_execute(operation, payload, opts)
      end

      result = if idempotent do
        RetryPolicy.with_retry(execute_fn, opts)
      else
        execute_fn.()
      end

      # Record result for circuit breaker
      case result do
        {:ok, _} -> CircuitBreaker.record_success(device: device)
        {:error, _} -> CircuitBreaker.record_failure(device: device)
      end

      result
    end
  end

  defp do_execute(operation, payload, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    # Get worker from pool
    case WorkerPool.checkout(opts) do
      {:ok, worker} ->
        try do
          Worker.execute(worker, operation, payload, timeout)
        after
          WorkerPool.checkin(worker)
        end

      {:error, :no_workers} ->
        {:error, %{type: :no_workers, message: "No workers available"}}
    end
  end
end
```

## Configuration

```elixir
config :snakepit, :crash_barrier,
  enabled: true,

  # Worker settings
  worker_restart_delay_ms: 100,
  worker_max_crashes: 10,
  worker_crash_window_ms: 60_000,

  # Circuit breaker
  circuit_failure_threshold: 5,
  circuit_success_threshold: 3,
  circuit_open_duration_ms: 30_000,

  # Retry policy
  retry_max_attempts: 3,
  retry_backoff: :exponential,
  retry_initial_delay_ms: 100,
  retry_max_delay_ms: 5000,

  # Health monitoring
  health_check_interval_ms: 10_000,
  crash_history_retention_ms: 3_600_000
```

## Telemetry Events

The crash barrier emits these telemetry events:

```elixir
# Worker crash
[:snakepit, :worker, :crash]
# Measurements: %{count: 1}
# Metadata: %{type: :segfault | :oom | ..., device: term()}

# Circuit breaker opens
[:snakepit, :circuit_breaker, :open]
# Measurements: %{failure_count: integer()}
# Metadata: %{device: term()}

# Circuit breaker closes
[:snakepit, :circuit_breaker, :close]
# Measurements: %{success_count: integer()}
# Metadata: %{device: term()}

# Retry attempted
[:snakepit, :retry, :attempt]
# Measurements: %{attempt: integer(), delay_ms: integer()}
# Metadata: %{operation: string()}

# Health alert
[:snakepit, :health, :alert]
# Measurements: %{crash_count: integer()}
# Metadata: %{alert_type: atom()}
```

## Testing

```elixir
defmodule Snakepit.CrashBarrierTest do
  use ExUnit.Case

  describe "worker crash recovery" do
    test "worker restarts after segfault" do
      # Trigger segfault in worker
      result = Snakepit.execute("test.trigger_segfault", %{})
      assert {:error, %{type: :worker_crash}} = result

      # Next request should work (new worker)
      assert {:ok, _} = Snakepit.execute("test.simple", %{})
    end

    test "idempotent operations retry automatically" do
      # First call will fail, second will succeed
      result = Snakepit.execute("test.flaky", %{}, idempotent: true)
      assert {:ok, _} = result
    end
  end

  describe "circuit breaker" do
    test "opens after repeated failures" do
      # Trigger multiple failures
      for _ <- 1..5 do
        Snakepit.execute("test.always_fail", %{})
      end

      # Circuit should be open
      assert {:error, :circuit_open} = Snakepit.CircuitBreaker.allow?()
    end
  end
end
```

## Implementation Phases

### Phase 1: Basic Isolation (Week 1)
- [ ] Port-based worker execution
- [ ] Exit status classification
- [ ] Basic restart logic

### Phase 2: Circuit Breaker (Week 2)
- [ ] CircuitBreaker GenServer
- [ ] Per-device circuits
- [ ] Telemetry events

### Phase 3: Health Monitoring (Week 3)
- [ ] HealthMonitor GenServer
- [ ] Crash pattern detection
- [ ] Health status API

### Phase 4: Retry & Polish (Week 4)
- [ ] RetryPolicy implementation
- [ ] Integration with Executor
- [ ] Documentation and tests

## SnakeBridge Integration

SnakeBridge can leverage crash barriers by:

1. **Marking idempotent operations** in generated wrappers
2. **Surfacing health status** in generated module metadata
3. **Including crash info** in error translation

See: `snakebridge/docs/20251227/world-class-ml/03-ml-error-translation.md`
