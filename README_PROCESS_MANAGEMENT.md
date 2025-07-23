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
- Generated using `:erlang.unique_integer([:positive, :monotonic])`
- Stored with each process registration
- Used to identify orphans from previous runs

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
   # Generate unique BEAM run ID
   beam_run_id = :erlang.unique_integer([:positive, :monotonic])
   
   # Open DETS file
   {:ok, dets_table} = :dets.open_file(@dets_table, [
     {:file, to_charlist(dets_file)},
     {:type, :set},
     {:auto_save, 1000}  # Auto-save every second
   ])
   ```

2. **Orphan Cleanup**
   ```elixir
   # Find processes from previous runs
   orphans = :dets.select(dets_table, [
     {{:"$1", :"$2"}, 
      [{:"/=", {:map_get, :beam_run_id, :"$2"}, current_beam_run_id}], 
      [{{:"$1", :"$2"}}]}
   ])
   
   # Clean up each orphan
   Enum.each(orphans, fn {worker_id, info} ->
     if process_alive?(info.process_pid) do
       # Try graceful shutdown
       System.cmd("kill", ["-TERM", to_string(info.process_pid)])
       Process.sleep(2000)
       
       # Force kill if needed
       if process_alive?(info.process_pid) do
         System.cmd("kill", ["-KILL", to_string(info.process_pid)])
       end
     end
   end)
   ```

### Worker Registration

When a new worker starts:

```elixir
worker_info = %{
  elixir_pid: elixir_pid,
  process_pid: process_pid,
  fingerprint: fingerprint,
  registered_at: System.system_time(:second),
  beam_run_id: state.beam_run_id,
  pgid: process_pid  # Process Group ID
}

# Write to both ETS and DETS
:ets.insert(state.table, {worker_id, worker_info})
:dets.insert(state.dets_table, {worker_id, worker_info})
```

### Periodic Health Checks

Every 30 seconds, ProcessRegistry:
- Checks for dead Elixir processes
- Removes stale entries
- Maintains registry consistency

## Benefits

1. **No Manual Cleanup Required**: Python processes are automatically cleaned up, even after `kill -9` on BEAM
2. **Production Ready**: Handles edge cases like VM crashes, OOM kills, and power failures
3. **Zero Configuration**: Works out of the box with sensible defaults
4. **Transparent**: No changes required to existing code

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

## Future Enhancements

Planned improvements include:

1. **Process Group Support**: Using `setsid` for better subprocess management
2. **Configurable Settings**: Expose cleanup intervals and timeouts
3. **Health Metrics**: Telemetry integration for monitoring
4. **Startup Hooks**: Allow custom cleanup strategies

## Technical Details

For implementation details, see:
- `lib/snakepit/pool/process_registry.ex` - Core implementation
- `docs/specs/proc_mgmt/` - Design specifications