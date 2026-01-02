# Production Deployment

This guide covers deploying Snakepit in production environments, including setup, process management, troubleshooting, and performance tuning.

## Pre-Deployment Checklist

Before deploying Snakepit to production:

- [ ] Python 3.10+ installed (3.13+ for thread-safe adapters)
- [ ] Virtual environment created with dependencies installed
- [ ] `SNAKEPIT_PYTHON` environment variable set (if not using system Python)
- [ ] gRPC proto files compiled (`mix snakepit.setup`)
- [ ] Pool size appropriate for workload
- [ ] Logging level set (`:warning` or `:error` for production)
- [ ] Telemetry handlers attached
- [ ] DETS storage directory writable (`priv/data/`)

## Mix Tasks

### mix snakepit.setup

Bootstrap the environment, installing Python dependencies and compiling gRPC protos:

```bash
mix snakepit.setup
```

### mix snakepit.doctor

Run environment diagnostics:

```bash
mix snakepit.doctor
```

Checks Python version, gRPC tools, proto files, and virtual environment configuration.

### mix snakepit.status

Check pool status and worker health:

```bash
mix snakepit.status
```

Output:

```
Pool: default (process)
  Workers: 8
  Queued: 0
  Requests: 1523
  Errors: 2
```

### mix snakepit.gen.adapter

Generate a Python adapter skeleton:

```bash
mix snakepit.gen.adapter my_adapter
```

Creates `priv/python/my_adapter/` with `adapter.py`. Configure with:

```elixir
adapter_args: ["--adapter", "my_adapter.adapter.MyAdapter"]
```

## Process Management

### Run IDs and Orphan Detection

Each BEAM instance gets a unique run ID on startup, enabling identification of workers belonging to the current process and detection of orphaned workers from crashed instances.

### Automatic Cleanup on Restart

When Snakepit starts, it automatically:

1. Identifies processes from previous BEAM runs using run IDs
2. Sends SIGTERM for graceful shutdown
3. Sends SIGKILL to unresponsive processes
4. Cleans up stale registry entries

Only processes matching Snakepit's command-line patterns (`grpc_server.py` with `--snakepit-run-id`) are considered. To disable:

```elixir
config :snakepit, :rogue_cleanup, enabled: false
```

### Graceful Shutdown

During application shutdown:

1. Workers receive SIGTERM (2 second timeout)
2. Unresponsive workers receive SIGKILL
3. Final `pkill` safety net for missed processes

### Manual Cleanup

```elixir
case Snakepit.cleanup() do
  :ok -> Logger.info("Cleanup completed")
  {:timeout, pids} -> Logger.warning("Some processes did not terminate")
end
```

## Script Mode (run_as_script/2)

For short-lived scripts and Mix tasks:

```elixir
defmodule Mix.Tasks.MyApp.ProcessData do
  use Mix.Task

  def run(args) do
    Snakepit.run_as_script(fn ->
      {:ok, result} = Snakepit.execute("process_batch", %{input: args})
      IO.puts("Complete: #{inspect(result)}")
    end, timeout: 30_000, cleanup_timeout: 10_000, exit_mode: :auto)
  end
end
```

Defaults are `exit_mode: :none` and `stop_mode: :if_started`. Use `exit_mode: :auto`
for scripts that may run under `--no-halt`, and set `stop_mode: :never` for embedded
usage where the host VM must stay alive.

Warning: `exit_mode: :halt` or `:stop` terminates the entire VM regardless of `stop_mode`.

Options: `:timeout`, `:shutdown_timeout`, `:cleanup_timeout`, `:exit_mode`, `:stop_mode`
(`:halt` is legacy and deprecated).

## Common Troubleshooting

### Python Process Will Not Start

```bash
mix snakepit.doctor      # Check environment
echo $SNAKEPIT_PYTHON    # Verify Python path
python3 -c "import grpc" # Test gRPC import
```

Solutions: Set `SNAKEPIT_PYTHON`, verify dependencies, check adapter module path.

### gRPC Connection Failures

```elixir
Snakepit.list_workers()  # Check running workers
Snakepit.get_stats()     # Check pool stats
```

Solutions: Check port conflicts, firewall rules, compile proto files.

### Memory Issues

```elixir
:telemetry.attach("mem", [:snakepit, :worker, :recycled],
  fn _, _, meta, _ -> IO.inspect(meta) end, nil)
```

Solutions: Increase `memory_threshold_mb`, reduce `pool_size`, enable worker TTL.

### Orphaned Processes

```bash
ps aux | grep grpc_server.py
pkill -f "grpc_server.py.*--snakepit-run-id"  # Manual cleanup
```

Orphans are cleaned automatically on next startup.

## Performance Tuning

### Pool Size Selection

```elixir
%{name: :default, pool_size: System.schedulers_online() * 2}
```

| Workload | Pool Size |
|----------|-----------|
| CPU-bound | `schedulers * 1-2` |
| I/O-bound | `schedulers * 4-8` |
| Mixed | `schedulers * 2-4` |

For thread-profile workers:

```elixir
%{name: :hpc, worker_profile: :thread, pool_size: 4, threads_per_worker: 16}
```

### Batch Configuration

```elixir
%{
  pool_size: 100,
  startup_batch_size: 8,
  startup_batch_delay_ms: 750
}
```

### Heartbeat Tuning

```elixir
heartbeat: %{
  enabled: true,
  ping_interval_ms: 2000,
  timeout_ms: 10000,
  max_missed_heartbeats: 3
}
```

| Environment | Interval | Timeout | Max Missed |
|-------------|----------|---------|------------|
| Development | 5000ms | 30000ms | 5 |
| Production | 2000ms | 10000ms | 3 |
| Critical | 1000ms | 5000ms | 2 |

## Complete Production Configuration

```elixir
# config/prod.exs
config :snakepit,
  pooling_enabled: true,
  log_level: :warning,

  pools: [
    %{
      name: :default,
      worker_profile: :process,
      pool_size: System.schedulers_online() * 2,
      adapter_module: Snakepit.Adapters.GRPCPython,
      adapter_args: ["--adapter", "myapp.adapter.MainAdapter"],
      startup_batch_size: 8,
      startup_batch_delay_ms: 750,
      worker_ttl: {1, :hours},
      worker_max_requests: 10_000,
      heartbeat: %{
        enabled: true,
        ping_interval_ms: 2000,
        timeout_ms: 10000,
        max_missed_heartbeats: 3
      }
    },
    %{
      name: :hpc,
      worker_profile: :thread,
      pool_size: 4,
      threads_per_worker: 16,
      adapter_args: ["--adapter", "myapp.adapter.MLAdapter"],
      heartbeat: %{enabled: true, ping_interval_ms: 5000}
    }
  ],

  pool_queue_timeout: 5000,
  pool_max_queue_size: 1000,
  pool_startup_timeout: 30000,

  crash_barrier: %{
    enabled: true,
    retry: :idempotent,
    max_retries: 1,
    taint_ms: 5000
  },

  rogue_cleanup: %{enabled: true},

  telemetry_metrics: %{prometheus: %{enabled: true}},

  opentelemetry: %{
    enabled: true,
    exporters: %{otlp: %{endpoint: "http://collector:4318"}}
  }
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `SNAKEPIT_PYTHON` | Path to Python binary |
| `SNAKEPIT_SCRIPT_EXIT` | Exit behavior for scripts (`none`, `halt`, `stop`, `auto`) |
| `SNAKEPIT_SCRIPT_HALT` | Deprecated; use `SNAKEPIT_SCRIPT_EXIT=halt` |
| `SNAKEPIT_OTEL_ENDPOINT` | OpenTelemetry collector endpoint |

## Deployment Recommendations

1. **Use Releases** - Build OTP releases for production
2. **Separate Python Env** - Use a dedicated virtual environment
3. **Monitor Early** - Attach telemetry handlers before starting pools
4. **Start Conservative** - Begin with smaller pool sizes
5. **Test Failure Modes** - Verify orphan cleanup and crash recovery
