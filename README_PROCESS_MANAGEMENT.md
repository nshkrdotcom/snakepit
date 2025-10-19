# Snakepit Process Management & Reliability

## Overview

Snakepit v0.3.3+ includes enhanced process management with persistent tracking and automatic orphan cleanup. This ensures that Python worker processes are always properly managed, even after unexpected BEAM VM crashes.

## Key Features

### 1. **Persistent Process Registry with DETS**

The ProcessRegistry now uses both ETS (in-memory) and DETS (disk-based) storage to track worker processes:

- **ETS**: Fast in-memory access for runtime operations
- **DETS**: Persistent storage that survives BEAM crashes
- **Location**: Process data is stored in `priv/data/process_registry.dets`

### 2. **Automatic Orphan Cleanup**

When Snakepit starts, it automatically:

1. Identifies processes from previous BEAM runs using unique run IDs
2. Attempts graceful shutdown (SIGTERM) for orphaned processes
3. Force kills (SIGKILL) any processes that don't respond
4. Cleans up stale registry entries

### 3. **BEAM Run Identification**

Each BEAM instance gets a unique run ID:
- Generated using timestamp + random component for guaranteed uniqueness
- Format: `"#{System.system_time(:microsecond)}_#{:rand.uniform(999_999)}"`
- Stored with each process registration
- Used to identify orphans from previous runs

### 4. **Script and Demo Support**

For short-lived scripts and demos, use `Snakepit.run_as_script/2`:
- Ensures pool is fully initialized before execution
- Guarantees proper cleanup of all processes on exit
- No orphaned processes after script completion

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Snakepit Application                      │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────────┐    ┌──────────────────────────────┐  │
│  │ Process Registry│    │     Worker Supervisor        │  │
│  │                 │    │                              │  │
│  │ ┌─────────────┐ │    │  ┌────────┐  ┌────────┐    │  │
│  │ │    ETS      │ │    │  │Worker 1│  │Worker 2│    │  │
│  │ │  (Memory)   │ │    │  │        │  │        │    │  │
│  │ └─────────────┘ │    │  └────┬───┘  └────┬───┘    │  │
│  │                 │    │       │            │        │  │
│  │ ┌─────────────┐ │    └───────┼────────────┼────────┘  │
│  │ │    DETS     │ │            │            │            │
│  │ │   (Disk)    │ │            ↓            ↓            │
│  │ └─────────────┘ │    ┌──────────────────────────────┐  │
│  └─────────────────┘    │   Python gRPC Processes      │  │
└─────────────────────────┴──────────────────────────────┘  │
```

## How It Works

### Startup Sequence

1. **ProcessRegistry Initialization**
   ```elixir
   # Generate unique BEAM run ID with timestamp + random
   timestamp = System.system_time(:microsecond)
   random_component = :rand.uniform(999_999)
   beam_run_id = "#{timestamp}_#{random_component}"
   
   # Open DETS file with node-specific naming
   node_name = node() |> to_string() |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")
   dets_file = Path.join([priv_dir, "data", "process_registry_#{node_name}.dets"])
   
   {:ok, dets_table} = :dets.open_file(@dets_table, [
     {:file, to_charlist(dets_file)},
     {:type, :set},
     {:auto_save, 1000},  # Auto-save every second
     {:repair, true}      # Auto-repair corrupted files
   ])
   ```

2. **Enhanced Orphan Cleanup (v0.3.4+)**
   ```elixir
   # Find ALL entries from previous runs
   all_entries = :dets.match_object(dets_table, :_)
   
   # 1. Clean up ACTIVE processes with known PIDs
   old_run_orphans = :dets.select(dets_table, [
     {{:"$1", :"$2"}, 
      [{:andalso, 
        {:"/=", {:map_get, :beam_run_id, :"$2"}, current_beam_run_id},
        {:orelse,
          {:==, {:map_get, :status, :"$2"}, :active},
          {:==, {:map_size, :"$2"}, 6}  # Legacy entries
        }
      }], 
      [{{:"$1", :"$2"}}]}
   ])
   
   # 2. Clean up RESERVED slots (processes that started but never activated)
   abandoned_reservations = 
     all_entries
     |> Enum.filter(fn {_id, info} ->
       Map.get(info, :status) == :reserved and 
       (info.beam_run_id != current_beam_run_id or 
        (now - Map.get(info, :reserved_at, 0)) > 60)
     end)
   
   # Kill processes using beam_run_id for safety
   Enum.each(abandoned_reservations, fn {worker_id, info} ->
     kill_pattern = "grpc_server.py.*--snakepit-run-id #{info.beam_run_id}"
     System.cmd("pkill", ["-9", "-f", kill_pattern])
   end)
   ```

### Pre-Registration Pattern (v0.3.4+)

The worker registration now follows a two-phase commit pattern to prevent orphans:

#### Phase 1: Reserve Before Spawn
```elixir
# In GRPCWorker.init/1 - BEFORE spawning the process
case Snakepit.Pool.ProcessRegistry.reserve_worker(worker_id) do
  :ok ->
    # Reservation is persisted to DETS with immediate sync
    # Now safe to spawn the process
    port = Port.open({:spawn_executable, setsid_path}, port_opts)
    # ...
  
  {:error, reason} ->
    # Failed to reserve, don't spawn
    {:stop, {:reservation_failed, reason}}
end
```

#### Phase 2: Activate After Spawn
```elixir
# In GRPCWorker.handle_continue/2 - AFTER process is running
process_pid = Port.info(server_port, :os_pid)

# Activate the reservation with actual process info
Snakepit.Pool.ProcessRegistry.activate_worker(
  worker_id,
  self(),
  process_pid,
  "grpc_worker"
)
```

### Worker Registration Details

The registration process now uses status tracking:

```elixir
# Phase 1: Reservation
reservation_info = %{
  status: :reserved,
  reserved_at: System.system_time(:second),
  beam_run_id: state.beam_run_id
}
:dets.insert(state.dets_table, {worker_id, reservation_info})
:dets.sync(state.dets_table)  # IMMEDIATE persistence

# Phase 2: Activation
worker_info = %{
  status: :active,
  elixir_pid: elixir_pid,
  process_pid: process_pid,
  fingerprint: fingerprint,
  registered_at: System.system_time(:second),
  beam_run_id: state.beam_run_id,
  pgid: process_pid
}
:ets.insert(state.table, {worker_id, worker_info})
:dets.insert(state.dets_table, {worker_id, worker_info})
:dets.sync(state.dets_table)  # IMMEDIATE persistence
```

### Periodic Health Checks

Every 30 seconds, ProcessRegistry:
- Checks for dead Elixir processes
- Removes stale entries
- Maintains registry consistency

### Application Shutdown

The ApplicationCleanup module ensures clean shutdown:
- Traps exits to guarantee `terminate/2` is called
- Sends SIGTERM to all processes for graceful shutdown
- Falls back to SIGKILL for unresponsive processes
- Final safety net using `pkill` for any missed processes

## Benefits

# Heartbeat Configuration

Snakepit now ships with a bidirectional heartbeat channel between BEAM and the
Python bridge.  The feature is **off by default** so the existing behaviour is
unchanged, but you can opt-in at either the application or pool level.

```elixir
# config/config.exs
config :snakepit,
  heartbeat: %{
    enabled: true,
    ping_interval_ms: 1_000,
    timeout_ms: 5_000,
    max_missed_heartbeats: 3,
    initial_delay_ms: 0
  }
```

- The map above seeds the defaults for every pool.  Worker-specific overrides
  can be supplied via the existing pool configuration:

  ```elixir
  pools: [
    %{
      name: :default,
      worker_profile: :process,
      pool_size: 32,
      heartbeat: %{enabled: true, ping_interval_ms: 2_000}
    }
  ]
  ```

- When `enabled: true`, the Elixir side starts `Snakepit.HeartbeatMonitor` for
  each worker and the Python server spins up a matching
  `snakepit_bridge.HeartbeatClient` once a session is initialised.  Disabling
  the flag immediately stops the monitor and client again.

Tune the intervals to balance responsiveness with overhead.  A good starting
point is a 1–2 s ping interval with a 5–10 s timeout and `max_missed_heartbeats`
set to 3.

1. **No Manual Cleanup Required**: Python processes are automatically cleaned up, even after `kill -9` on BEAM
2. **Production Ready**: Handles edge cases like VM crashes, OOM kills, and power failures
3. **Zero Configuration**: Works out of the box with sensible defaults
4. **Transparent**: No changes required to existing code
5. **Prevents Race Conditions (v0.3.4+)**: Pre-registration pattern ensures no orphans even when crashing during worker startup
6. **Immediate Persistence**: All DETS operations use sync() to prevent data loss on abrupt termination

## Configuration

Currently, the process management system uses these defaults:

- **DETS file location**: `priv/data/process_registry.dets`
- **Cleanup interval**: 30 seconds
- **Graceful shutdown timeout**: 2 seconds

Future versions may expose these as configuration options.

## Monitoring

To monitor the process registry:

```elixir
# Get registry statistics
Snakepit.Pool.ProcessRegistry.get_stats()
# => %{
#   total_registered: 4,
#   alive_workers: 4,
#   dead_workers: 0,
#   active_process_pids: 4
# }

# List all workers
Snakepit.Pool.ProcessRegistry.list_all_workers()

# Check specific worker
Snakepit.Pool.ProcessRegistry.get_worker_info("worker_id")
```

## Troubleshooting

### Verifying Orphan Cleanup

1. Start Snakepit and note the Python process PIDs:
   ```bash
   ps aux | grep grpc_server.py
   ```

2. Kill the BEAM process abruptly:
   ```bash
   kill -9 <beam_pid>
   ```

3. Verify Python processes are still running:
   ```bash
   ps aux | grep grpc_server.py
   ```

4. Restart Snakepit and check logs for cleanup:
   ```
   [warning] Starting orphan cleanup for BEAM run 2
   [warning] Found orphaned process 12345 from previous BEAM run 1. Terminating...
   [info] Orphan cleanup complete. Killed 4 orphaned processes.
   ```

### DETS File Management

The DETS file is automatically managed, but if needed:

- **Location**: `<app>/priv/data/process_registry.dets`
- **Safe to delete**: Yes, when Snakepit is not running
- **Auto-created**: Yes, on startup if missing

### Common Issues

1. **"DETS file not properly closed" warning**
   - Normal after crash, file is automatically repaired
   - No action needed

2. **Orphaned processes not cleaned**
   - Check if processes are zombies: `ps aux | grep defunct`
   - Verify DETS file permissions
   - Check logs for cleanup errors

3. **Slow startup**
   - Large number of orphans can slow initial cleanup
   - Normal operation resumes after cleanup

4. **Processes remain after Mix tasks**
   - Use `Snakepit.run_as_script/2` for short-lived scripts
   - This ensures proper application shutdown
   - Example:
     ```elixir
     Snakepit.run_as_script(fn ->
       # Your code here
     end)
     ```

## Observability Quickstart

1. **Install bridge dependencies** – `python3 -m venv .venv && .venv/bin/pip install -r priv/python/requirements.txt`
2. **Point Snakepit at the venv** – export `SNAKEPIT_PYTHON="$PWD/.venv/bin/python3"` so the worker port launches with OTEL + pytest available.
3. **Enable metrics** – set `config :snakepit, telemetry_metrics: %{prometheus: %{enabled: true}}` (dev/test) and run `curl http://localhost:9568/metrics` to confirm heartbeat counters and pool gauges.
4. **Enable tracing** – set `config :snakepit, opentelemetry: %{enabled: true, exporters: %{console: %{enabled: true}}}` locally or point `SNAKEPIT_OTEL_ENDPOINT=http://collector:4318` at your collector. Python logs include `corr=<id>` when correlation headers flow across the bridge.

## Future Enhancements

Planned improvements include:

1. **Configurable Settings**: Expose cleanup intervals and timeouts
2. **Health Metrics**: Telemetry integration for monitoring
3. **Startup Hooks**: Allow custom cleanup strategies
4. **Distributed Process Management**: Support for multi-node deployments

## Technical Details

For implementation details, see:
- `lib/snakepit/pool/process_registry.ex` - Core implementation
- `docs/specs/proc_mgmt/` - Design specifications
