# Robust Process Management Specification

**Feature Name:** Robust Process Management  
**Priority:** P0 (Critical)  
**Status:** Design Phase  
**Target Release:** Snakepit v0.7.0  
**Estimated Effort:** 2-3 weeks  
**Dependencies:** None (foundational feature)

## Executive Summary

The Robust Process Management feature addresses the #1 production blocker identified in expert feedback: unreliable process lifecycle management that can leave orphaned Python processes when the BEAM VM crashes unexpectedly. This feature implements a BEAM-native solution using heartbeat patterns, self-terminating workers, and comprehensive telemetry to ensure zero orphaned processes and full observability of worker health.

## Problem Statement

### Current Issues
1. **Orphaned Processes**: When BEAM crashes, Python workers continue running indefinitely
2. **No Health Monitoring**: Limited visibility into worker process health and lifecycle
3. **Supervisord Dependency**: Proposed external dependency adds operational complexity
4. **Race Conditions**: Process cleanup has timing issues and race conditions
5. **Poor Observability**: Insufficient telemetry for production monitoring

### Impact
- Production deployments experience resource leaks
- Difficult to debug worker issues in production
- Manual cleanup required after BEAM crashes
- No early warning for worker health problems

## Solution Overview

Replace the current fragile process management with a robust, BEAM-native solution:

1. **Heartbeat Pattern**: Bidirectional health monitoring between BEAM and Python
2. **Self-Termination**: Python workers detect BEAM crashes and exit cleanly
3. **Watchdog Process**: Optional lightweight monitor for paranoid scenarios
4. **Comprehensive Telemetry**: Full observability of all process lifecycle events

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    BEAM VM (Elixir)                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────────┐    ┌─────────────────────────────┐   │
│  │   GRPCWorker     │    │    HeartbeatMonitor        │   │
│  │   (GenServer)    │◄──►│    (GenServer)             │   │
│  │                  │    │                             │   │
│  │  • Send PING     │    │  • Track heartbeats        │   │
│  │  • Expect PONG   │    │  • Detect timeouts         │   │
│  │  • Monitor port  │    │  • Emit telemetry          │   │
│  └─────────┬────────┘    └─────────────────────────────┘   │
│            │ Port/gRPC                                     │
└────────────┼─────────────────────────────────────────────────┘
             │
┌────────────▼─────────────────────────────────────────────────┐
│                  Python Worker Process                      │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────────┐    ┌─────────────────────────────┐   │
│  │  gRPC Server     │    │   HeartbeatClient          │   │
│  │                  │◄──►│                             │   │
│  │  • Handle PING   │    │  • Send PONG responses      │   │
│  │  • Send PONG     │    │  • Detect broken pipe      │   │
│  │  • Normal ops    │    │  • Self-terminate on crash │   │
│  └──────────────────┘    └─────────────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Watchdog Process (Optional)            │   │
│  │                                                     │   │
│  │  • Monitor BEAM PID                                 │   │
│  │  • Kill Python worker if BEAM dies                 │   │
│  │  • Lightweight shell script                        │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## Components

### 1. Heartbeat Pattern
- **Bidirectional**: BEAM sends PING, Python responds with PONG
- **Configurable Intervals**: Default 2s interval, 10s timeout
- **Failure Detection**: Missing heartbeats trigger worker restart
- **Self-Termination**: Python detects broken pipe and exits

### 2. Orphaned Process Prevention
- **Pipe Monitoring**: Python monitors stdout/stderr pipes to BEAM
- **Signal Handling**: Graceful shutdown on SIGTERM, forced on SIGKILL
- **Process Groups**: Use process groups for atomic cleanup
- **Resource Cleanup**: Ensure all child processes are terminated

### 3. Watchdog Process
- **Optional Component**: For paranoid deployment scenarios
- **Lightweight**: Simple shell script, minimal resource usage
- **PID Monitoring**: Watches BEAM process, kills Python if BEAM dies
- **Platform Support**: Linux, macOS, with Windows considerations

### 4. Process Lifecycle Telemetry
- **Comprehensive Events**: All lifecycle transitions emit telemetry
- **Rich Metadata**: Process IDs, timestamps, failure reasons
- **Performance Metrics**: Startup time, heartbeat latency, cleanup duration
- **Integration Ready**: Prometheus, Grafana, LiveDashboard compatible

## Success Criteria

### Functional Requirements
- ✅ Zero orphaned processes after BEAM crash (100% success rate)
- ✅ Worker health detection within 10 seconds of failure
- ✅ Automatic worker restart without Pool intervention
- ✅ Graceful shutdown during application termination
- ✅ Cross-platform support (Linux, macOS, Windows)

### Performance Requirements
- ✅ Heartbeat overhead <1% of worker capacity
- ✅ Worker startup time unchanged (<3s for 100 workers)
- ✅ Process cleanup completes within 5 seconds
- ✅ Telemetry events have <1ms overhead

### Operational Requirements
- ✅ No external dependencies (pure BEAM/OTP solution)
- ✅ Configurable timeouts and intervals
- ✅ Comprehensive logging and error reporting
- ✅ Production-ready monitoring dashboards

## Implementation Phases

### Phase 1: Heartbeat Foundation (Week 1)
- Implement HeartbeatMonitor GenServer
- Add heartbeat support to Python gRPC server
- Basic PING/PONG protocol
- Unit tests for heartbeat logic

### Phase 2: Self-Termination (Week 1-2)
- Python pipe monitoring implementation
- Signal handling and graceful shutdown
- Process group management
- Integration tests for crash scenarios

### Phase 3: Watchdog Process (Week 2)
- Shell script watchdog implementation
- Platform-specific variations
- Integration with worker startup
- Testing across platforms

### Phase 4: Telemetry & Monitoring (Week 2-3)
- Comprehensive telemetry events
- Prometheus metrics integration
- Grafana dashboard templates
- Performance optimization

### Phase 5: Production Hardening (Week 3)
- Chaos testing integration
- Edge case handling
- Documentation and examples
- Performance benchmarking

## Risk Mitigation

### Technical Risks
- **Platform Differences**: Extensive testing on Linux, macOS, Windows
- **Race Conditions**: Careful synchronization and atomic operations
- **Performance Impact**: Benchmarking and optimization throughout
- **Signal Handling**: Robust signal handling across platforms

### Operational Risks
- **Backward Compatibility**: Feature flags for gradual rollout
- **Configuration Complexity**: Sensible defaults, minimal config required
- **Debugging Difficulty**: Comprehensive logging and telemetry
- **Production Impact**: Thorough testing before release

## Testing Strategy

### Unit Tests
- HeartbeatMonitor state transitions
- Python heartbeat client logic
- Signal handling edge cases
- Telemetry event emission

### Integration Tests
- End-to-end heartbeat flow
- Worker crash and restart scenarios
- Graceful shutdown behavior
- Cross-platform compatibility

### Chaos Tests
- BEAM process kill (SIGKILL)
- Network partition simulation
- Resource exhaustion scenarios
- Concurrent worker failures

### Performance Tests
- Heartbeat overhead measurement
- Large-scale worker deployment
- Long-running stability tests
- Memory leak detection

## Monitoring & Observability

### Key Metrics
- Worker heartbeat success rate
- Heartbeat response latency
- Worker restart frequency
- Process cleanup duration
- Orphaned process count

### Telemetry Events
- `[:snakepit, :worker, :heartbeat, :sent]`
- `[:snakepit, :worker, :heartbeat, :received]`
- `[:snakepit, :worker, :heartbeat, :timeout]`
- `[:snakepit, :worker, :process, :started]`
- `[:snakepit, :worker, :process, :terminated]`
- `[:snakepit, :worker, :cleanup, :completed]`

### Dashboards
- Real-time worker health status
- Heartbeat latency trends
- Process lifecycle timeline
- Failure rate analysis

## Documentation Requirements

### User Documentation
- Configuration guide with examples
- Troubleshooting common issues
- Performance tuning recommendations
- Platform-specific considerations

### Developer Documentation
- Architecture decision records
- API reference for telemetry events
- Testing strategies and examples
- Contributing guidelines

### Operational Documentation
- Monitoring setup guide
- Alert configuration examples
- Incident response procedures
- Capacity planning guidelines

## Success Metrics

### Before Implementation
- Orphaned process rate: ~30% after BEAM crashes
- Worker health visibility: Limited logging only
- Failure detection time: Manual discovery (minutes to hours)
- Production confidence: Low due to resource leaks

### After Implementation
- Orphaned process rate: 0% (target)
- Worker health visibility: Real-time dashboards
- Failure detection time: <10 seconds automated
- Production confidence: High with comprehensive monitoring

## Future Enhancements

### v0.8.0 Considerations
- Distributed heartbeat coordination
- Advanced failure prediction
- Machine learning-based health scoring
- Integration with service mesh monitoring

### Long-term Vision
- Self-healing worker pools
- Predictive failure prevention
- Advanced resource optimization
- Cross-language process management patterns

## Conclusion

The Robust Process Management feature transforms Snakepit from a development tool into a production-ready platform by eliminating the #1 operational concern: orphaned processes and poor observability. This BEAM-native solution provides comprehensive process lifecycle management without external dependencies, setting the foundation for reliable production deployments.