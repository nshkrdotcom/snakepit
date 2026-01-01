# Snakepit Configuration Guide

This guide covers all configuration options for Snakepit, from simple single-pool setups to advanced multi-pool deployments with different worker profiles.

---

## Table of Contents

1. [Configuration Formats](#configuration-formats)
2. [Global Options](#global-options)
3. [Pool Configuration](#pool-configuration)
4. [Heartbeat Configuration](#heartbeat-configuration)
5. [Logging Configuration](#logging-configuration)
6. [Python Runtime Configuration](#python-runtime-configuration)
7. [Optional Features](#optional-features)
8. [Complete Configuration Example](#complete-configuration-example)

---

## Configuration Formats

Snakepit supports two configuration formats: legacy (single-pool) and multi-pool (v0.6+).

### Simple (Legacy) Configuration

For backward compatibility with v0.5.x and single-pool deployments:

```elixir
# config/config.exs
config :snakepit,
  pooling_enabled: true,
  adapter_module: Snakepit.Adapters.GRPCPython,
  pool_size: 100,
  pool_config: %{
    startup_batch_size: 8,
    startup_batch_delay_ms: 750,
    max_workers: 1000
  }
```

This format creates a single pool named `:default` with the specified settings.

### Multi-Pool Configuration (v0.6+)

For advanced deployments with multiple pools, each with different profiles:

```elixir
# config/config.exs
config :snakepit,
  pools: [
    %{
      name: :default,
      worker_profile: :process,
      pool_size: 100,
      adapter_module: Snakepit.Adapters.GRPCPython
    },
    %{
      name: :ml_inference,
      worker_profile: :thread,
      pool_size: 4,
      threads_per_worker: 16,
      adapter_module: Snakepit.Adapters.GRPCPython,
      adapter_args: ["--adapter", "myapp.ml.InferenceAdapter"]
    }
  ]
```

This creates two pools: `:default` for general tasks and `:ml_inference` for CPU-bound ML workloads.

---

## Global Options

These options apply to all pools or the Snakepit application as a whole.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `pooling_enabled` | `boolean()` | `false` | Enable or disable worker pooling. Set to `true` for normal operation. |
| `adapter_module` | `module()` | `nil` | Default adapter module for pools that do not specify one. |
| `pool_size` | `pos_integer()` | `System.schedulers_online() * 2` | Default pool size. Typically 2x CPU cores. |
| `capacity_strategy` | `:pool \| :profile \| :hybrid` | `:pool` | How worker capacity is managed across pools. |
| `pool_startup_timeout` | `pos_integer()` | `10000` | Maximum time (ms) to wait for a worker to start. |
| `pool_queue_timeout` | `pos_integer()` | `5000` | Maximum time (ms) a request waits in queue. |
| `pool_max_queue_size` | `pos_integer()` | `1000` | Maximum queued requests before rejecting new ones. |
| `grpc_port` | `pos_integer()` | `50051` | Port for the Elixir gRPC server (Python-to-Elixir calls). |
| `grpc_host` | `String.t()` | `"localhost"` | Host for gRPC connections. |
| `graceful_shutdown_timeout_ms` | `pos_integer()` | `6000` | Time (ms) to wait for Python to terminate gracefully before SIGKILL. |

### Capacity Strategies

| Strategy | Description |
|----------|-------------|
| `:pool` | Each pool manages its own capacity independently. Default and simplest option. |
| `:profile` | Workers of the same profile share capacity across pools. |
| `:hybrid` | Combination of pool and profile strategies for complex deployments. |

---

## Pool Configuration

Each pool can be configured independently with these options.

### Required Fields

| Option | Type | Description |
|--------|------|-------------|
| `name` | `atom()` | Unique pool identifier. Use `:default` for the primary pool. |

### Profile Selection

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `worker_profile` | `:process \| :thread` | `:process` | Worker execution model. See [Worker Profiles Guide](worker-profiles.md). |

### Common Pool Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `pool_size` | `pos_integer()` | Global setting | Number of workers in this pool. |
| `adapter_module` | `module()` | Global setting | Adapter module for this pool. |
| `adapter_args` | `list(String.t())` | `[]` | CLI arguments passed to the Python server. |
| `adapter_env` | `list({String.t(), String.t()})` | `[]` | Environment variables for Python processes. |
| `adapter_spec` | `String.t()` | `nil` | Python adapter module path (e.g., `"myapp.adapters.MyAdapter"`). |

### Process Profile Options

These options apply when `worker_profile: :process`:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `startup_batch_size` | `pos_integer()` | `8` | Workers started per batch during pool initialization. |
| `startup_batch_delay_ms` | `non_neg_integer()` | `750` | Delay between startup batches (ms). Reduces system load during startup. |

### Thread Profile Options

These options apply when `worker_profile: :thread`:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `threads_per_worker` | `pos_integer()` | `10` | Thread pool size per Python process. Total capacity = `pool_size * threads_per_worker`. |
| `thread_safety_checks` | `boolean()` | `false` | Enable runtime thread safety validation. Useful for development. |

### Worker Lifecycle Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `worker_ttl` | `:infinity \| {value, unit}` | `:infinity` | Maximum worker lifetime before recycling. |
| `worker_max_requests` | `:infinity \| pos_integer()` | `:infinity` | Maximum requests before recycling a worker. |

**TTL Units:**

| Unit | Example |
|------|---------|
| `:seconds` | `{3600, :seconds}` - 1 hour |
| `:minutes` | `{60, :minutes}` - 1 hour |
| `:hours` | `{1, :hours}` - 1 hour |

Worker recycling helps prevent memory leaks and ensures fresh worker state.

---

## Heartbeat Configuration

Heartbeats detect unresponsive workers and trigger automatic restarts.

### Global Heartbeat Config

```elixir
config :snakepit,
  heartbeat: %{
    enabled: true,
    ping_interval_ms: 2000,
    timeout_ms: 10000,
    max_missed_heartbeats: 3,
    initial_delay_ms: 0,
    dependent: true
  }
```

### Per-Pool Heartbeat Config

```elixir
%{
  name: :ml_pool,
  heartbeat: %{
    enabled: true,
    ping_interval_ms: 10000,
    timeout_ms: 30000,
    max_missed_heartbeats: 2
  }
}
```

### Heartbeat Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | `boolean()` | `true` | Enable heartbeat monitoring. |
| `ping_interval_ms` | `pos_integer()` | `2000` | Interval between heartbeat pings. |
| `timeout_ms` | `pos_integer()` | `10000` | Maximum time to wait for heartbeat response. |
| `max_missed_heartbeats` | `pos_integer()` | `3` | Missed heartbeats before declaring worker dead. |
| `initial_delay_ms` | `non_neg_integer()` | `0` | Delay before first heartbeat ping. |
| `dependent` | `boolean()` | `true` | Whether worker terminates if heartbeat monitor dies. |

### Tuning Guidelines

- **Fast detection**: Lower `ping_interval_ms` and `max_missed_heartbeats`
- **Reduce overhead**: Higher `ping_interval_ms` for stable workloads
- **Long operations**: Increase `timeout_ms` if workers run long computations
- **ML workloads**: Use `ping_interval_ms: 10000` or higher since inference can block

---

## Logging Configuration

Snakepit uses its own logger for internal operations.

### Log Level

```elixir
config :snakepit,
  log_level: :info  # :debug | :info | :warning | :error | :none
```

| Level | Description |
|-------|-------------|
| `:debug` | Verbose output including worker lifecycle, gRPC calls, heartbeats |
| `:info` | Normal operation messages |
| `:warning` | Potential issues that do not stop operation |
| `:error` | Errors that affect functionality |
| `:none` | Disable all Snakepit logging |

### Log Categories

Fine-grained control over logging categories:

```elixir
config :snakepit,
  log_level: :info,
  log_categories: %{
    pool: :debug,      # Pool operations
    worker: :debug,    # Worker lifecycle
    heartbeat: :info,  # Heartbeat monitoring
    grpc: :warning     # gRPC communication
  }
```

### Python-Side Logging

The Python bridge respects the `SNAKEPIT_LOG_LEVEL` environment variable:

```elixir
%{
  name: :default,
  adapter_env: [{"SNAKEPIT_LOG_LEVEL", "info"}]
}
```

---

## Python Runtime Configuration

Configure how Python interpreters are discovered and managed.

### Interpreter Selection

```elixir
config :snakepit,
  python_executable: "/path/to/python3"
```

Or use environment variable (takes precedence):

```bash
export SNAKEPIT_PYTHON="/path/to/python3"
```

### Runtime Strategy

```elixir
config :snakepit,
  python_runtime: %{
    strategy: :venv,  # :system | :venv | :managed
    managed: false,
    version: "3.12"
  }
```

| Strategy | Description |
|----------|-------------|
| `:system` | Use system Python interpreter |
| `:venv` | Use project virtual environment (`.venv/bin/python3`) |
| `:managed` | Let Snakepit manage Python version (experimental) |

### Environment Variables per Pool

```elixir
%{
  name: :ml_pool,
  adapter_env: [
    # Control threading in numerical libraries
    {"OPENBLAS_NUM_THREADS", "1"},
    {"MKL_NUM_THREADS", "1"},
    {"OMP_NUM_THREADS", "1"},
    {"NUMEXPR_NUM_THREADS", "1"},

    # GPU configuration
    {"CUDA_VISIBLE_DEVICES", "0"},

    # Python settings
    {"PYTHONUNBUFFERED", "1"},
    {"SNAKEPIT_LOG_LEVEL", "warning"}
  ]
}
```

---

## Optional Features

### Zero-Copy Data Transfer

Enable zero-copy for large binary data:

```elixir
config :snakepit,
  zero_copy: %{
    enabled: true,
    threshold_bytes: 1_048_576  # 1 MB
  }
```

Zero-copy is beneficial for ML workloads with large tensors.

### Crash Barrier

Limit restart attempts for frequently crashing workers:

```elixir
config :snakepit,
  crash_barrier: %{
    enabled: true,
    max_restarts: 5,
    window_seconds: 60
  }
```

If a worker restarts more than `max_restarts` times within `window_seconds`, it is permanently removed from the pool.

### Circuit Breaker

Prevent cascading failures:

```elixir
config :snakepit,
  circuit_breaker: %{
    enabled: true,
    failure_threshold: 5,
    reset_timeout_ms: 30000
  }
```

After `failure_threshold` consecutive failures, the circuit opens and requests fail fast for `reset_timeout_ms`.

---

## Complete Configuration Example

Here is a production-ready configuration demonstrating all major options:

```elixir
# config/config.exs
config :snakepit,
  # Global settings
  pooling_enabled: true,
  pool_startup_timeout: 30_000,
  pool_queue_timeout: 10_000,
  pool_max_queue_size: 5000,
  grpc_port: 50051,

  # Logging
  log_level: :info,
  log_categories: %{
    pool: :info,
    worker: :warning,
    heartbeat: :warning,
    grpc: :warning
  },

  # Global heartbeat defaults
  heartbeat: %{
    enabled: true,
    ping_interval_ms: 5000,
    timeout_ms: 15000,
    max_missed_heartbeats: 3
  },

  # Multiple pools
  pools: [
    # Default pool for I/O-bound tasks
    %{
      name: :default,
      worker_profile: :process,
      pool_size: 50,
      adapter_module: Snakepit.Adapters.GRPCPython,
      adapter_args: ["--adapter", "myapp.adapters.GeneralAdapter"],
      adapter_env: [
        {"OPENBLAS_NUM_THREADS", "1"},
        {"OMP_NUM_THREADS", "1"}
      ],
      startup_batch_size: 10,
      startup_batch_delay_ms: 500
    },

    # ML inference pool (CPU-bound, thread profile)
    %{
      name: :ml_inference,
      worker_profile: :thread,
      pool_size: 4,
      threads_per_worker: 8,  # 32 total capacity
      adapter_module: Snakepit.Adapters.GRPCPython,
      adapter_args: ["--adapter", "myapp.ml.InferenceAdapter"],
      adapter_env: [
        {"OPENBLAS_NUM_THREADS", "8"},
        {"OMP_NUM_THREADS", "8"},
        {"CUDA_VISIBLE_DEVICES", "0"},
        {"PYTORCH_CUDA_ALLOC_CONF", "max_split_size_mb:512"}
      ],
      thread_safety_checks: false,
      worker_ttl: {1800, :seconds},
      worker_max_requests: 10000,
      heartbeat: %{
        enabled: true,
        ping_interval_ms: 10000,
        timeout_ms: 60000,
        max_missed_heartbeats: 2
      }
    },

    # Background processing pool
    %{
      name: :background,
      worker_profile: :process,
      pool_size: 10,
      adapter_module: Snakepit.Adapters.GRPCPython,
      adapter_args: ["--adapter", "myapp.adapters.BackgroundAdapter"],
      adapter_env: [
        {"SNAKEPIT_LOG_LEVEL", "warning"}
      ],
      worker_ttl: {3600, :seconds}
    }
  ],

  # Optional features
  crash_barrier: %{
    enabled: true,
    max_restarts: 10,
    window_seconds: 300
  }
```

### Environment-Specific Overrides

```elixir
# config/prod.exs
config :snakepit,
  log_level: :warning,
  pool_max_queue_size: 10000

# config/dev.exs
config :snakepit,
  log_level: :debug,
  pool_size: 4

# config/test.exs
config :snakepit,
  pooling_enabled: false
```

---

## Validation

Verify your configuration with the doctor task:

```bash
mix snakepit.doctor
```

At runtime, check pool status:

```elixir
iex> Snakepit.get_stats()
%{
  requests: 15432,
  queued: 5,
  errors: 12,
  queue_timeouts: 3,
  pool_saturated: 0,
  workers: 54,
  available: 49,
  busy: 5
}
```

---

## Related Guides

- [Getting Started](getting-started.md) - Installation and first steps
- [Worker Profiles](worker-profiles.md) - Process vs Thread profiles
- [Production](production.md) - Performance tuning and deployment checklist
