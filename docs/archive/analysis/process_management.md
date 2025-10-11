# Process Management Documentation

## Overview

Snakepit uses sophisticated process management to ensure external worker processes (Python gRPC servers) are properly tracked and cleaned up. This system prevents orphaned processes and ensures clean shutdowns.

## Architecture

### Components

1. **ProcessRegistry** - Persistent tracking of worker processes using DETS
2. **ApplicationCleanup** - Final safety net during application shutdown
3. **GRPCWorker** - Individual worker process management with graceful shutdown
4. **BEAM Run ID** - Unique identifier for each BEAM VM run to distinguish processes

### Process Lifecycle

1. Worker starts external process using `setsid` for process group management
2. Process PID and PGID are registered with ProcessRegistry
3. During normal operation, processes are monitored via health checks
4. On shutdown:
   - Workers attempt graceful SIGTERM shutdown
   - ApplicationCleanup ensures no processes survive
   - Orphaned processes from previous runs are cleaned on startup

## POSIX Platform Requirements

This process management system requires a POSIX-compliant platform with the following utilities:

### Required Commands

- **`setsid`** - Creates new session and process group
  - Location: `/usr/bin/setsid` or in PATH
  - Used for: Process group isolation

- **`kill`** - Send signals to processes
  - Required signals: TERM, KILL, 0 (existence check)
  - Process group support: `kill -SIGNAL -PGID`

- **`ps`** - Process status inspection
  - Required options: `-p PID -o cmd=`
  - Used for: Verifying process identity before killing

- **`pkill`** - Pattern-based process killing
  - Required options: `-f` (full command line match)
  - Used for: Final cleanup fallback

### Platform Compatibility

✅ **Supported:**
- Linux (all distributions)
- macOS/Darwin
- FreeBSD
- WSL/WSL2

❌ **Not Supported:**
- Windows (native - use WSL instead)
- Non-POSIX systems

### Signal Handling

The system uses standard POSIX signals:
- **SIGTERM (15)** - Graceful shutdown request
- **SIGKILL (9)** - Force termination
- **Signal 0** - Process existence check

## Configuration

### Environment Variables

- `SNAKEPIT_CLEANUP_TIMEOUT` - Time to wait for graceful shutdown (default: 2000ms)
- `SNAKEPIT_ORPHAN_CHECK_INTERVAL` - Interval for orphan process checks (default: 30000ms)

### Node Naming

The DETS persistence file is namespaced by node name to prevent conflicts:
```
priv/data/process_registry_<sanitized_node_name>.dets
```

## Security Considerations

1. **Targeted Cleanup** - Only kills processes matching:
   - Registered PIDs
   - Command contains "grpc_server.py"
   - Matches current BEAM run ID

2. **Process Verification** - Always verifies process identity before killing

3. **No Broad Patterns** - Avoids dangerous patterns that could affect system processes

## Troubleshooting

### Common Issues

1. **Orphaned Processes**
   - Check DETS file persistence
   - Verify BEAM run ID is being passed to Python processes
   - Check `setsid` availability

2. **Cleanup Failures**
   - Verify user has permission to kill processes
   - Check if processes are in uninterruptible state
   - Look for zombie processes

### Debug Commands

```bash
# Check for orphaned Python processes
ps aux | grep grpc_server.py

# View process groups
ps -eo pid,pgid,cmd | grep grpc_server

# Manual cleanup (emergency only)
pkill -9 -f "grpc_server.py.*--snakepit-run-id"
```

## Future Enhancements

### Systemd Integration (Linux)

For production Linux deployments, consider systemd service with:
- Process tracking via cgroups
- Automatic cleanup on service stop
- Resource limits

### Docker/Container Support

When running in containers:
- Ensure PID 1 handles signals properly
- Consider using `dumb-init` or `tini`
- Map process namespaces correctly