# Systemd/Cgroups Integration Research

## Executive Summary

Systemd and cgroups provide robust process management capabilities that could enhance Snakepit's reliability, especially in production Linux environments. This document outlines potential integration approaches.

## Current Limitations

Our current approach using `setsid` and manual process tracking has limitations:
- PIDs can be recycled
- Process group killing requires careful handling
- No resource limits enforcement
- Manual cleanup can miss edge cases

## Systemd Integration Benefits

### 1. Transient Services
Create transient systemd services for each worker:
```bash
systemd-run --uid=user --gid=group --scope \
  --property="Delegate=yes" \
  --property="KillMode=mixed" \
  --property="KillSignal=SIGTERM" \
  python grpc_server.py
```

Benefits:
- Automatic cleanup when parent dies
- Proper signal propagation
- Resource accounting

### 2. Cgroup-based Tracking
Each worker in its own cgroup:
```
/sys/fs/cgroup/snakepit.slice/
├── snakepit-worker-1.scope
├── snakepit-worker-2.scope
└── snakepit-worker-3.scope
```

Benefits:
- Reliable process enumeration
- Cannot escape cleanup
- Resource limits (CPU, memory)

## Implementation Approaches

### Option 1: Systemd-run Wrapper
```elixir
defmodule Snakepit.SystemdWorker do
  def start_process(script, args) do
    systemd_args = [
      "--uid=#{System.get_env("USER")}",
      "--scope",
      "--property=KillMode=mixed",
      "--property=CPUQuota=50%",
      "--property=MemoryMax=1G",
      "--",
      script
    ] ++ args
    
    Port.open({:spawn_executable, "/usr/bin/systemd-run"}, 
      [:binary, :exit_status, args: systemd_args])
  end
end
```

### Option 2: Direct Cgroup Management
```elixir
defmodule Snakepit.CgroupManager do
  @cgroup_root "/sys/fs/cgroup/snakepit.slice"
  
  def create_worker_cgroup(worker_id) do
    cgroup_path = Path.join(@cgroup_root, "worker-#{worker_id}")
    File.mkdir_p!(cgroup_path)
    
    # Set limits
    File.write!(Path.join(cgroup_path, "memory.max"), "1G")
    File.write!(Path.join(cgroup_path, "cpu.max"), "50000 100000")
    
    cgroup_path
  end
  
  def add_process_to_cgroup(cgroup_path, pid) do
    File.write!(Path.join(cgroup_path, "cgroup.procs"), "#{pid}")
  end
end
```

## Resource Limits

### Memory Limits
```ini
MemoryMax=1G          # Hard limit
MemoryHigh=768M       # Soft limit (throttling starts)
MemorySwapMax=0       # Disable swap
```

### CPU Limits
```ini
CPUQuota=50%          # 50% of one CPU
CPUWeight=100         # Default priority
CPUAccounting=yes     # Enable accounting
```

### IO Limits
```ini
IOWeight=100          # IO priority
IOReadBandwidthMax=/dev/sda 10M
IOWriteBandwidthMax=/dev/sda 10M
```

## Integration Considerations

### Pros
1. **Reliability** - Kernel-enforced cleanup
2. **Resource Control** - Prevent runaway processes
3. **Monitoring** - Built-in metrics via systemd
4. **Security** - Process isolation

### Cons
1. **Linux-only** - Not portable to macOS/BSD
2. **Complexity** - Additional dependency
3. **Permissions** - May require systemd user session
4. **Overhead** - Slight performance impact

## Implementation Recommendation

### Phase 1: Optional Systemd Backend
- Detect systemd availability at runtime
- Fall back to current setsid approach
- Configuration option to enable/disable

### Phase 2: Cgroup Resource Limits
- Add resource limit configuration
- Monitor resource usage
- Alert on limit violations

### Phase 3: Full Integration
- Systemd socket activation
- Journal logging integration
- Prometheus metrics export

## Example Configuration

```elixir
config :snakepit, :process_manager,
  backend: :systemd,  # :setsid | :systemd | :cgroup
  systemd_opts: [
    slice: "snakepit.slice",
    kill_mode: :mixed,
    kill_signal: :SIGTERM,
    timeout_stop_sec: 5
  ],
  resource_limits: [
    memory_max: "1G",
    cpu_quota: "50%",
    io_weight: 100
  ]
```

## Testing Strategy

1. **Unit Tests** - Mock systemd commands
2. **Integration Tests** - Require systemd environment
3. **Stress Tests** - Verify cleanup under load
4. **Resource Tests** - Verify limits enforced

## Conclusion

Systemd/cgroups integration would provide significant benefits for production deployments while maintaining compatibility with the current approach. A phased implementation allows gradual adoption and testing.