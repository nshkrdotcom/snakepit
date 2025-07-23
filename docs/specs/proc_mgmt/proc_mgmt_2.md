# Snakepit Process Management: Alternative Approaches and Extended Solutions

## Introduction

This document complements the original process management specification by exploring alternative architectures, edge cases, and production-hardening strategies that weren't covered in depth. While the original focused on DETS persistence and process groups, we'll examine additional approaches that could provide even more robust guarantees.

## Alternative Architectural Patterns

### 1. Process Proxy Pattern

Instead of direct process management, introduce a lightweight proxy process that acts as an intermediary:

```elixir
defmodule Snakepit.ProcessProxy do
  @moduledoc """
  A proxy that monitors both BEAM parent and Python child.
  If either dies, it ensures cleanup of the other.
  """
  
  def start_link(python_command) do
    # Start a small C program or Rust binary that:
    # 1. Monitors parent BEAM process via prctl(PR_SET_PDEATHSIG)
    # 2. Spawns and monitors Python child
    # 3. Kills Python if BEAM dies
    # 4. Exits if Python dies
    
    proxy_path = Application.app_dir(:snakepit, "priv/snakepit_proxy")
    beam_pid = System.pid()
    
    Port.open({:spawn_executable, proxy_path}, [
      :binary,
      args: [beam_pid, python_command | python_args]
    ])
  end
end
```

**Advantages:**
- Works even with `kill -9` on BEAM
- No persistent state needed
- Handles parent death at OS level

**Implementation in C:**
```c
// snakepit_proxy.c
#include <sys/prctl.h>
#include <signal.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    // Set to receive SIGTERM when parent dies
    prctl(PR_SET_PDEATHSIG, SIGTERM);
    
    // Fork and exec Python process
    pid_t python_pid = fork();
    if (python_pid == 0) {
        execvp(argv[2], &argv[2]);
    }
    
    // Wait for either signal or child exit
    int status;
    waitpid(python_pid, &status, 0);
    return 0;
}
```

### 2. Systemd Integration Pattern

For production Linux systems, leverage systemd's process tracking:

```ini
# /etc/systemd/system/snakepit-worker@.service
[Unit]
Description=Snakepit Worker %i
PartOf=snakepit.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/snakepit/grpc_server.py --port=%i
Restart=always
RestartSec=5

# Critical: Kill all processes in the cgroup
KillMode=control-group
TimeoutStopSec=10
```

```elixir
defmodule Snakepit.SystemdWorkerManager do
  def start_worker(worker_id, port) do
    # Start via systemd
    {output, 0} = System.cmd("systemctl", [
      "start", 
      "snakepit-worker@#{port}.service"
    ])
    
    # Track in ETS only (systemd handles persistence)
    ProcessRegistry.register_systemd_unit(worker_id, "snakepit-worker@#{port}")
  end
  
  def cleanup_all_workers() do
    # Systemd tracks all our units
    {output, _} = System.cmd("systemctl", [
      "stop", 
      "snakepit-worker@*.service"
    ])
  end
end
```

### 3. Container-Based Isolation

Use lightweight containers for absolute process isolation:

```elixir
defmodule Snakepit.ContainerWorkerManager do
  def start_worker(worker_id, config) do
    # Use runc or crun for lightweight containers
    container_id = "snakepit-#{worker_id}-#{System.unique_integer()}"
    
    config_json = Jason.encode!(%{
      "ociVersion" => "1.0.0",
      "process" => %{
        "terminal" => false,
        "user" => %{"uid" => 1000, "gid" => 1000},
        "args" => ["/usr/bin/python3", "/app/grpc_server.py"],
        "env" => ["PATH=/usr/bin", "SNAKEPIT_PORT=#{config.port}"],
        "cwd" => "/app"
      },
      "root" => %{"path" => "/var/lib/snakepit/rootfs"},
      "linux" => %{
        "namespaces" => [
          %{"type" => "pid"},
          %{"type" => "ipc"},
          %{"type" => "mount"}
        ]
      }
    })
    
    File.write!("/tmp/#{container_id}/config.json", config_json)
    
    port = Port.open({:spawn_executable, "/usr/bin/runc"}, [
      :binary,
      args: ["run", "-d", "--bundle", "/tmp/#{container_id}", container_id]
    ])
    
    {:ok, container_id}
  end
end
```

## Extended Edge Cases and Solutions

### 1. Zombie Process Prevention

Even with process groups, zombies can accumulate if not properly reaped:

```elixir
defmodule Snakepit.ZombieReaper do
  use GenServer
  
  def init(_) do
    # Set up SIGCHLD handler to reap zombies
    :os.set_signal(:sigchld, :handle)
    {:ok, %{}}
  end
  
  def handle_info({:signal, :sigchld}, state) do
    # Reap all available zombies
    reap_zombies()
    {:noreply, state}
  end
  
  defp reap_zombies() do
    case :os.wait() do
      {:ok, _pid, _status} -> reap_zombies()  # Keep reaping
      {:error, :echild} -> :ok  # No more children
      {:error, :eintr} -> reap_zombies()  # Interrupted, retry
    end
  end
end
```

### 2. Resource Limit Enforcement

Prevent runaway Python processes from consuming all resources:

```elixir
defmodule Snakepit.ResourceLimiter do
  def apply_limits(port_or_pid) do
    os_pid = get_os_pid(port_or_pid)
    
    # Memory limit: 2GB
    System.cmd("prlimit", [
      "--pid=#{os_pid}",
      "--as=2147483648"
    ])
    
    # CPU limit: 90% of one core
    System.cmd("cpulimit", [
      "--pid=#{os_pid}",
      "--limit=90",
      "--background"
    ])
    
    # File descriptor limit
    System.cmd("prlimit", [
      "--pid=#{os_pid}",
      "--nofile=1024"
    ])
  end
end
```

### 3. Network Namespace Isolation

For multi-tenant scenarios, isolate network access:

```elixir
defmodule Snakepit.NetworkIsolation do
  def create_isolated_worker(worker_id, allowed_ports) do
    netns = "snakepit-#{worker_id}"
    
    # Create network namespace
    System.cmd("ip", ["netns", "add", netns])
    
    # Set up veth pair
    System.cmd("ip", ["link", "add", "veth-#{worker_id}", "type", "veth", 
                      "peer", "name", "veth-#{worker_id}-ns"])
    
    # Move one end to namespace
    System.cmd("ip", ["link", "set", "veth-#{worker_id}-ns", "netns", netns])
    
    # Configure networking with iptables rules
    setup_firewall_rules(netns, allowed_ports)
    
    # Start process in namespace
    Port.open({:spawn_executable, "/usr/bin/ip"}, [
      :binary,
      args: ["netns", "exec", netns, "python3", "/app/grpc_server.py"]
    ])
  end
end
```

## Monitoring and Observability

### 1. Process Lifecycle Events

Track detailed lifecycle events for debugging:

```elixir
defmodule Snakepit.ProcessLifecycleTracker do
  def track_event(worker_id, event_type, metadata) do
    event = %{
      worker_id: worker_id,
      event_type: event_type,
      timestamp: System.os_time(:nanosecond),
      beam_node: node(),
      metadata: metadata
    }
    
    # Write to time-series database
    :telemetry.execute(
      [:snakepit, :process, :lifecycle],
      %{count: 1},
      event
    )
    
    # Also append to audit log
    File.write!("/var/log/snakepit/lifecycle.jsonl", 
                Jason.encode!(event) <> "\n", [:append])
  end
end
```

### 2. Health Score Calculation

Beyond binary alive/dead checks:

```elixir
defmodule Snakepit.ProcessHealthScorer do
  def calculate_health_score(worker_info) do
    scores = %{
      memory_usage: score_memory_usage(worker_info.os_pid),
      cpu_usage: score_cpu_usage(worker_info.os_pid),
      response_time: score_response_time(worker_info.last_ping),
      restart_count: score_restart_count(worker_info.restart_count),
      uptime: score_uptime(worker_info.started_at)
    }
    
    # Weighted average
    weights = %{memory_usage: 0.2, cpu_usage: 0.2, response_time: 0.3, 
                restart_count: 0.2, uptime: 0.1}
    
    Enum.reduce(scores, 0, fn {metric, score}, acc ->
      acc + score * weights[metric]
    end)
  end
  
  defp score_memory_usage(pid) do
    # Read from /proc/[pid]/status
    case File.read("/proc/#{pid}/status") do
      {:ok, content} ->
        # Parse VmRSS and score based on thresholds
        parse_memory_score(content)
      _ -> 0
    end
  end
end
```

## Recovery Strategies

### 1. Gradual Degradation

Instead of killing all orphans immediately, implement gradual degradation:

```elixir
defmodule Snakepit.GracefulOrphanHandler do
  def handle_orphan(worker_info) do
    age = DateTime.diff(DateTime.utc_now(), worker_info.registered_at)
    
    cond do
      age < 300 ->  # Less than 5 minutes
        # Recent orphan - might be temporary network issue
        Logger.info("Found recent orphan #{worker_info.os_pid}, monitoring...")
        schedule_recheck(worker_info, 60)
        
      age < 3600 ->  # Less than 1 hour
        # Try graceful shutdown first
        Logger.warning("Attempting graceful shutdown of orphan #{worker_info.os_pid}")
        send_signal(worker_info.os_pid, :term)
        schedule_force_kill(worker_info, 30)
        
      true ->
        # Old orphan - immediate termination
        Logger.error("Force killing old orphan #{worker_info.os_pid}")
        send_signal(worker_info.pgid, :kill, :group)
    end
  end
end
```

### 2. State Reconstruction

For stateful workers, attempt state recovery:

```elixir
defmodule Snakepit.StateRecovery do
  def attempt_recovery(dead_worker_info) do
    # Check if worker left state dump
    state_file = "/var/lib/snakepit/state/#{dead_worker_info.worker_id}.state"
    
    case File.read(state_file) do
      {:ok, state_data} ->
        # Start new worker with recovered state
        new_worker = start_worker_with_state(dead_worker_info.config, state_data)
        
        # Verify state was loaded correctly
        case verify_state_recovery(new_worker, state_data) do
          :ok -> 
            Logger.info("Successfully recovered state for worker #{dead_worker_info.worker_id}")
            {:ok, new_worker}
          :error ->
            Logger.error("State recovery failed for worker #{dead_worker_info.worker_id}")
            {:error, :state_recovery_failed}
        end
        
      {:error, _} ->
        Logger.warning("No state file found for worker #{dead_worker_info.worker_id}")
        {:error, :no_state_file}
    end
  end
end
```

## Production Hardening Checklist

### Pre-Deployment
- [ ] Test with `kill -9` on BEAM process
- [ ] Test with OOM killer scenarios
- [ ] Test with system reboot during operation
- [ ] Verify no orphans after 1000 start/stop cycles
- [ ] Test with Python processes that fork children
- [ ] Measure startup time with 100+ orphaned processes

### Monitoring Setup
- [ ] Alert on orphaned process detection
- [ ] Alert on high restart rates
- [ ] Dashboard showing process lifecycle metrics
- [ ] Log aggregation for Python process output
- [ ] Trace correlation between BEAM and Python logs

### Operational Procedures
- [ ] Document manual orphan cleanup procedure
- [ ] Create runbook for process leak investigation
- [ ] Set up automated orphan cleanup cron job (backup)
- [ ] Define SLOs for process startup/shutdown times

## Conclusion

While the original specification provides a solid foundation with DETS persistence and process groups, production environments may benefit from additional approaches:

1. **Process proxies** for absolute parent-death guarantees
2. **System integration** (systemd/containers) for battle-tested process management
3. **Comprehensive monitoring** for early detection of issues
4. **Graceful degradation** instead of aggressive killing
5. **State recovery** for improved reliability

The best approach depends on your specific requirements:
- For maximum reliability: Process proxy pattern
- For standard Linux deployments: Systemd integration  
- For multi-tenant isolation: Container approach
- For complex applications: Combine multiple strategies

Remember: Process management is about defense in depth. No single solution is perfect, but layering multiple approaches provides the robustness needed for production systems.