# Snakepit Process Management: Analysis and Recommendations

## Executive Summary

This document synthesizes the current state of process management in Snakepit, analyzes the gap between specification and implementation, and provides concrete recommendations for building a truly robust external process management system.

The core challenge is managing external Python processes that exist outside OTP's supervision tree. While the current implementation handles normal operations well, it lacks critical safeguards against VM crashes and orphaned processes.

## Current Implementation Status

### What's Working Well

1. **Clean Architecture**: The separation of concerns between `ProcessRegistry`, `ApplicationCleanup`, and `GRPCWorker` provides a solid foundation.

2. **Graceful Shutdown Path**: Workers attempt SIGTERM before SIGKILL, giving Python processes time to clean up.

3. **Automatic Restart**: The `Worker.Starter` permanent wrapper ensures crashed workers are automatically restarted.

4. **Final Safety Net**: `ApplicationCleanup` provides a last-resort cleanup during application shutdown.

### Critical Gaps

1. **No Persistence**: The `ProcessRegistry` uses only ETS (volatile memory), not DETS. When the BEAM crashes, all process tracking is lost.

2. **No Startup Cleanup**: There's no "scorched earth" routine to kill orphaned processes from previous runs.

3. **No Process Groups**: Python processes aren't isolated in their own process groups, making it impossible to kill child processes they might spawn.

4. **No Run Identification**: Without tracking which BEAM instance started each process, we can't distinguish between legitimate processes and orphans.

## The Robust Architecture: Enhanced Process Guardian System

### Core Principles

1. **Durability**: Process state must survive BEAM crashes via persistent storage
2. **Isolation**: Each external process runs in its own process group
3. **Identity**: Each BEAM run has a unique ID to identify its processes
4. **Redundancy**: Multiple layers of cleanup at startup, runtime, and shutdown

### Architectural Components

#### 1. Enhanced ProcessRegistry with DETS Persistence

```elixir
defmodule Snakepit.Pool.ProcessRegistry do
  @dets_table :snakepit_process_registry_dets
  @dets_file "/var/lib/snakepit/process_registry.dets"  # Persistent location
  
  defstruct [:ets_table, :dets_table, :beam_run_id]
  
  def init(_) do
    # Generate unique ID for this BEAM run
    beam_run_id = :erlang.unique_integer([:positive, :monotonic])
    
    # Open DETS for persistence
    {:ok, dets_table} = :dets.open_file(@dets_table, [
      {:file, @dets_file},
      {:type, :set},
      {:auto_save, 1000}  # Auto-save every 1000ms
    ])
    
    # Create ETS for fast access
    ets_table = :ets.new(@table, [:set, :public, :named_table])
    
    # Perform startup cleanup FIRST
    cleanup_orphaned_processes(dets_table, beam_run_id)
    
    # Load current run's processes into ETS
    load_current_run_processes(dets_table, ets_table, beam_run_id)
    
    {:ok, %__MODULE__{
      ets_table: ets_table,
      dets_table: dets_table,
      beam_run_id: beam_run_id
    }}
  end
end
```

#### 2. Process Group Management

Instead of directly spawning Python processes, use `setsid` for process group isolation:

```elixir
defmodule Snakepit.Pool.ProcessSpawner do
  def spawn_with_process_group(command, args) do
    # Use setsid to create new process group
    full_command = ["setsid", command | args]
    
    port_opts = [
      :binary,
      :exit_status,
      {:line, 1024},
      {:args, tl(full_command)}
    ]
    
    port = Port.open({:spawn_executable, hd(full_command)}, port_opts)
    
    # Get PID (which is also PGID for group leader)
    {:os_pid, pid} = Port.info(port, :os_pid)
    
    {:ok, port, pid, pid}  # pid is also pgid
  end
end
```

#### 3. Enhanced Worker Registration

```elixir
def register_worker(worker_id, worker_info) do
  enhanced_info = Map.merge(worker_info, %{
    beam_run_id: state.beam_run_id,
    registered_at: DateTime.utc_now(),
    pgid: worker_info.os_pid,  # When using setsid, PID = PGID
    command_path: worker_info.executable_path,
    command_args: worker_info.args
  })
  
  # Atomic write to both ETS and DETS
  :ets.insert(state.ets_table, {worker_id, enhanced_info})
  :dets.insert(state.dets_table, {worker_id, enhanced_info})
  
  Logger.info("Registered worker #{worker_id} with PID #{enhanced_info.os_pid} " <>
              "for BEAM run #{state.beam_run_id}")
end
```

#### 4. Startup Orphan Cleanup

```elixir
defp cleanup_orphaned_processes(dets_table, current_beam_run_id) do
  Logger.warning("Starting orphan cleanup for BEAM run #{current_beam_run_id}")
  
  # Get all processes from previous runs
  orphans = :dets.select(dets_table, [
    {{:"$1", :"$2"}, 
     [{:"/=", {:map_get, :beam_run_id, :"$2"}, current_beam_run_id}], 
     [{{:"$1", :"$2"}}]}
  ])
  
  Enum.each(orphans, fn {worker_id, info} ->
    if process_group_alive?(info.pgid) do
      Logger.warning("Found orphaned process group #{info.pgid} from previous " <>
                     "BEAM run #{info.beam_run_id}. Terminating...")
      
      # Kill entire process group
      System.cmd("kill", ["-KILL", "-#{info.pgid}"])
    end
    
    # Remove from DETS
    :dets.delete(dets_table, worker_id)
  end)
  
  Logger.info("Orphan cleanup complete. Killed #{length(orphans)} orphaned process groups.")
end
```

#### 5. Health Checker Process

```elixir
defmodule Snakepit.Pool.HealthChecker do
  use GenServer
  
  @check_interval :timer.seconds(30)
  
  def handle_info(:check_health, state) do
    # Get all registered processes
    all_processes = ProcessRegistry.get_all_processes()
    
    Enum.each(all_processes, fn {worker_id, info} ->
      cond do
        # Check if Elixir owner is dead but OS process lives
        not Process.alive?(info.elixir_pid) and process_alive?(info.pgid) ->
          Logger.warning("Worker #{worker_id} has dead Elixir owner but live " <>
                         "OS process #{info.pgid}. Killing orphan...")
          kill_process_group(info.pgid)
          ProcessRegistry.unregister_worker(worker_id)
          
        # Check if OS process is dead but registry entry exists
        not process_alive?(info.pgid) ->
          Logger.info("Worker #{worker_id} has dead OS process. Cleaning registry...")
          ProcessRegistry.unregister_worker(worker_id)
          
        true ->
          :ok  # Healthy
      end
    end)
    
    Process.send_after(self(), :check_health, @check_interval)
    {:noreply, state}
  end
end
```

### Implementation Roadmap

#### Phase 1: Add Persistence (Critical)
1. Modify `ProcessRegistry` to use DETS backing
2. Add `beam_run_id` tracking
3. Implement startup orphan cleanup
4. Test with `kill -9` scenarios

#### Phase 2: Process Group Isolation
1. Modify worker spawning to use `setsid`
2. Update kill commands to target process groups (`-PGID`)
3. Test with Python processes that spawn children

#### Phase 3: Active Health Monitoring
1. Add `HealthChecker` GenServer
2. Implement periodic orphan detection
3. Add metrics and alerting

#### Phase 4: Enhanced Python-side Robustness
1. Add parent process monitoring in Python
2. Implement heartbeat mechanism
3. Add comprehensive signal handling

### Testing Strategy

1. **Normal Operations**
   - Start/stop workers normally
   - Verify clean shutdown

2. **Crash Scenarios**
   - `kill -9` the BEAM
   - Verify orphan cleanup on restart

3. **Process Group Testing**
   - Create Python processes that spawn children
   - Verify all children are killed

4. **Race Conditions**
   - Rapid start/stop cycles
   - Concurrent worker operations

### Configuration Recommendations

```elixir
config :snakepit,
  process_registry: [
    dets_file: "/var/lib/snakepit/process_registry.dets",
    cleanup_on_startup: true,
    health_check_interval: :timer.seconds(30),
    startup_cleanup_timeout: :timer.seconds(10)
  ],
  
  worker_config: [
    use_process_groups: true,
    shutdown_grace_period: :timer.seconds(5),
    force_kill_timeout: :timer.seconds(2)
  ]
```

## Conclusion

The current Snakepit implementation provides a good foundation but lacks critical robustness features for production use. The primary risk is orphaned Python processes after BEAM crashes.

By implementing DETS persistence, process group isolation, and startup cleanup, we can achieve true "no process left behind" guarantees. The enhanced architecture provides multiple layers of defense against orphaned processes while maintaining the clean separation of concerns in the current design.

The implementation can be done incrementally, with Phase 1 (persistence) being the most critical for preventing orphaned processes. Each phase builds on the previous one, allowing for gradual improvement of the system's robustness.