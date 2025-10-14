# Implementation Tasks

## Phase 1: Heartbeat Foundation (Week 1)

### Task 1.1: HeartbeatMonitor GenServer
**Estimated Effort:** 2 days  
**Priority:** P0  
**Dependencies:** None

#### Subtasks:
- [ ] Create `lib/snakepit/heartbeat_monitor.ex` with GenServer implementation
- [ ] Implement ping/pong protocol state machine
- [ ] Add configurable intervals and timeouts
- [ ] Implement worker failure detection and restart triggering
- [ ] Add comprehensive logging and error handling
- [ ] Write unit tests for all state transitions

#### Acceptance Criteria:
- [ ] HeartbeatMonitor can be started with worker PID and configuration
- [ ] Sends periodic PING messages to workers via gRPC
- [ ] Tracks PONG responses and calculates latency
- [ ] Detects missed heartbeats and triggers worker restart after threshold
- [ ] Emits telemetry events for all heartbeat activities
- [ ] Handles worker process termination gracefully

#### Files to Create/Modify:
- `lib/snakepit/heartbeat_monitor.ex` (new)
- `test/snakepit/heartbeat_monitor_test.exs` (new)

---

### Task 1.2: Python Heartbeat Client
**Estimated Effort:** 2 days  
**Priority:** P0  
**Dependencies:** Task 1.1

#### Subtasks:
- [ ] Create `priv/python/snakepit_bridge/heartbeat.py` with HeartbeatClient class
- [ ] Implement PING message handling and PONG responses
- [ ] Add stdout pipe monitoring for broken pipe detection
- [ ] Implement signal handlers for graceful shutdown
- [ ] Add BEAM PID monitoring for crash detection
- [ ] Create gRPC servicer integration for heartbeat protocol
- [ ] Write comprehensive Python unit tests

#### Acceptance Criteria:
- [ ] HeartbeatClient responds to PING messages with PONG + timestamp
- [ ] Detects broken stdout pipe and self-terminates immediately
- [ ] Monitors BEAM PID and exits if BEAM process disappears
- [ ] Handles SIGTERM gracefully and SIGKILL forcefully
- [ ] Integrates with gRPC server for heartbeat protocol
- [ ] Provides statistics and health status information

#### Files to Create/Modify:
- `priv/python/snakepit_bridge/heartbeat.py` (new)
- `priv/python/snakepit_bridge/test_heartbeat.py` (new)
- `priv/python/grpc_server.py` (modify - add heartbeat integration)

---

### Task 1.3: gRPC Protocol Extension
**Estimated Effort:** 1 day  
**Priority:** P0  
**Dependencies:** Task 1.1, 1.2

#### Subtasks:
- [ ] Extend `priv/proto/snakepit_bridge.proto` with heartbeat messages
- [ ] Add PingRequest and PingResponse message definitions
- [ ] Update gRPC service definition with Ping RPC method
- [ ] Regenerate Elixir gRPC stubs
- [ ] Update Python gRPC server to handle Ping requests
- [ ] Test end-to-end gRPC heartbeat communication

#### Acceptance Criteria:
- [ ] PingRequest contains timestamp for latency calculation
- [ ] PingResponse contains success status and worker statistics
- [ ] Ping RPC method is properly defined in service
- [ ] Elixir can successfully call Ping on Python workers
- [ ] Python workers respond with valid PingResponse messages
- [ ] Protocol handles errors and timeouts gracefully

#### Files to Create/Modify:
- `priv/proto/snakepit_bridge.proto` (modify)
- `lib/snakepit/grpc/generated/` (regenerate)
- `priv/python/grpc_server.py` (modify)

---

### Task 1.4: GRPCWorker Integration
**Estimated Effort:** 1 day  
**Priority:** P0  
**Dependencies:** Task 1.1, 1.2, 1.3

#### Subtasks:
- [ ] Modify `lib/snakepit/grpc_worker.ex` to start HeartbeatMonitor
- [ ] Add heartbeat configuration options to worker initialization
- [ ] Implement `send_heartbeat_ping/2` function for gRPC calls
- [ ] Handle heartbeat responses and forward to HeartbeatMonitor
- [ ] Add heartbeat status to worker health checks
- [ ] Update worker termination to stop HeartbeatMonitor

#### Acceptance Criteria:
- [ ] GRPCWorker automatically starts HeartbeatMonitor on initialization
- [ ] Worker can send heartbeat pings via gRPC and receive responses
- [ ] Heartbeat configuration is passed through from pool configuration
- [ ] Worker health status includes heartbeat information
- [ ] HeartbeatMonitor is properly cleaned up on worker termination
- [ ] Integration works with existing worker lifecycle

#### Files to Create/Modify:
- `lib/snakepit/grpc_worker.ex` (modify)
- `test/snakepit/grpc_worker_test.exs` (modify)

---

## Phase 2: Self-Termination (Week 1-2)

### Task 2.1: Python Process Monitoring
**Estimated Effort:** 2 days  
**Priority:** P0  
**Dependencies:** Task 1.2

#### Subtasks:
- [ ] Enhance HeartbeatClient with comprehensive process monitoring
- [ ] Implement broken pipe detection with BrokenPipeError handling
- [ ] Add BEAM PID monitoring with periodic checks
- [ ] Implement signal handlers for SIGTERM, SIGINT, SIGPIPE
- [ ] Add emergency shutdown logic with immediate termination
- [ ] Create process group management for child process cleanup
- [ ] Write integration tests for all termination scenarios

#### Acceptance Criteria:
- [ ] Python worker detects broken stdout pipe within 1 second
- [ ] Worker monitors BEAM PID and exits if PID disappears
- [ ] Signal handlers provide graceful shutdown on SIGTERM
- [ ] Emergency shutdown uses os._exit(1) for immediate termination
- [ ] All child processes are terminated via process groups
- [ ] Self-termination works on Linux, macOS, and Windows

#### Files to Create/Modify:
- `priv/python/snakepit_bridge/heartbeat.py` (enhance)
- `priv/python/snakepit_bridge/test_process_monitoring.py` (new)

---

### Task 2.2: Process Group Management
**Estimated Effort:** 1 day  
**Priority:** P1  
**Dependencies:** Task 2.1

#### Subtasks:
- [ ] Modify Python worker startup to create new process group
- [ ] Implement process group termination in signal handlers
- [ ] Add platform-specific process group handling (Unix vs Windows)
- [ ] Test process group cleanup with child processes
- [ ] Ensure compatibility with existing process management
- [ ] Document process group behavior and limitations

#### Acceptance Criteria:
- [ ] Python worker creates new process group on startup
- [ ] Signal handlers terminate entire process group
- [ ] Child processes are automatically cleaned up
- [ ] Works correctly on all supported platforms
- [ ] No interference with existing BEAM process management
- [ ] Proper error handling for process group operations

#### Files to Create/Modify:
- `priv/python/grpc_server.py` (modify - add process group creation)
- `priv/python/snakepit_bridge/process_utils.py` (new)

---

### Task 2.3: Integration Testing
**Estimated Effort:** 2 days  
**Priority:** P0  
**Dependencies:** Task 2.1, 2.2

#### Subtasks:
- [ ] Create comprehensive integration tests for crash scenarios
- [ ] Test BEAM process kill (SIGKILL) with Python cleanup verification
- [ ] Test graceful BEAM shutdown with worker termination
- [ ] Test broken pipe scenarios with immediate self-termination
- [ ] Test signal handling with various signal types
- [ ] Create automated test scripts for CI/CD integration
- [ ] Add performance tests for termination speed

#### Acceptance Criteria:
- [ ] 100% success rate for orphaned process prevention in tests
- [ ] Python workers terminate within 5 seconds of BEAM crash
- [ ] All integration tests pass on Linux, macOS, Windows
- [ ] Automated tests can be run in CI/CD pipeline
- [ ] Performance tests verify termination speed requirements
- [ ] Tests cover edge cases and error conditions

#### Files to Create/Modify:
- `test/integration/process_management_test.exs` (new)
- `test/support/crash_test_helpers.ex` (new)
- `scripts/test_crash_scenarios.sh` (new)

---

## Phase 3: Watchdog Process (Week 2)

### Task 3.1: Shell Script Watchdog
**Estimated Effort:** 1 day  
**Priority:** P2  
**Dependencies:** None

#### Subtasks:
- [ ] Create `priv/scripts/watchdog.sh` with BEAM PID monitoring
- [ ] Implement graceful and forceful Python process termination
- [ ] Add configurable check intervals and grace periods
- [ ] Create platform-specific variants (Linux, macOS, Windows)
- [ ] Add comprehensive logging and error handling
- [ ] Test watchdog behavior in various scenarios

#### Acceptance Criteria:
- [ ] Watchdog monitors BEAM PID and detects when it disappears
- [ ] Sends SIGTERM to Python worker, escalates to SIGKILL if needed
- [ ] Configurable via environment variables
- [ ] Works on Linux, macOS, with Windows batch script variant
- [ ] Minimal resource usage (<1MB memory, <1% CPU)
- [ ] Proper logging for debugging and monitoring

#### Files to Create/Modify:
- `priv/scripts/watchdog.sh` (new)
- `priv/scripts/watchdog.bat` (new - Windows variant)
- `priv/scripts/test_watchdog.sh` (new)

---

### Task 3.2: Watchdog Integration
**Estimated Effort:** 1 day  
**Priority:** P2  
**Dependencies:** Task 3.1, Task 1.4

#### Subtasks:
- [ ] Add watchdog configuration options to GRPCWorker
- [ ] Implement watchdog process startup in worker initialization
- [ ] Add watchdog PID tracking and cleanup
- [ ] Create watchdog health monitoring and restart logic
- [ ] Test watchdog integration with existing worker lifecycle
- [ ] Add telemetry events for watchdog activities

#### Acceptance Criteria:
- [ ] Watchdog can be enabled/disabled via configuration
- [ ] GRPCWorker starts watchdog process with correct PIDs
- [ ] Watchdog process is properly cleaned up on worker termination
- [ ] Watchdog failures are detected and logged appropriately
- [ ] Integration doesn't interfere with normal worker operation
- [ ] Telemetry events provide visibility into watchdog status

#### Files to Create/Modify:
- `lib/snakepit/grpc_worker.ex` (modify - add watchdog support)
- `lib/snakepit/watchdog_manager.ex` (new)
- `test/snakepit/watchdog_integration_test.exs` (new)

---

### Task 3.3: Cross-Platform Testing
**Estimated Effort:** 1 day  
**Priority:** P2  
**Dependencies:** Task 3.1, 3.2

#### Subtasks:
- [ ] Test watchdog functionality on Linux systems
- [ ] Test watchdog functionality on macOS systems  
- [ ] Test watchdog functionality on Windows systems
- [ ] Verify process termination behavior across platforms
- [ ] Test edge cases and error conditions
- [ ] Create platform-specific CI/CD test jobs

#### Acceptance Criteria:
- [ ] Watchdog works correctly on all supported platforms
- [ ] Process termination behavior is consistent across platforms
- [ ] Platform-specific edge cases are handled properly
- [ ] CI/CD tests verify cross-platform functionality
- [ ] Documentation covers platform-specific considerations
- [ ] Error messages are clear and actionable

#### Files to Create/Modify:
- `.github/workflows/test-watchdog.yml` (new)
- `test/platform/watchdog_platform_test.exs` (new)

---

## Phase 4: Telemetry & Monitoring (Week 2-3)

### Task 4.1: Telemetry Events Implementation
**Estimated Effort:** 2 days  
**Priority:** P0  
**Dependencies:** Task 1.1, 2.1

#### Subtasks:
- [ ] Create `lib/snakepit/process_telemetry.ex` with event definitions
- [ ] Implement telemetry emission in HeartbeatMonitor
- [ ] Add telemetry events to Python HeartbeatClient
- [ ] Create telemetry events for process lifecycle
- [ ] Add telemetry events for watchdog activities
- [ ] Implement default telemetry handlers with logging
- [ ] Write tests for all telemetry events

#### Acceptance Criteria:
- [ ] All process management events emit structured telemetry
- [ ] Telemetry includes rich metadata and measurements
- [ ] Events are properly documented with schemas
- [ ] Default handlers provide useful logging
- [ ] Telemetry overhead is minimal (<1ms per event)
- [ ] Events can be consumed by external monitoring systems

#### Files to Create/Modify:
- `lib/snakepit/process_telemetry.ex` (new)
- `lib/snakepit/heartbeat_monitor.ex` (modify - add telemetry)
- `priv/python/snakepit_bridge/heartbeat.py` (modify - add telemetry)
- `test/snakepit/process_telemetry_test.exs` (new)

---

### Task 4.2: Prometheus Integration
**Estimated Effort:** 2 days  
**Priority:** P1  
**Dependencies:** Task 4.1

#### Subtasks:
- [ ] Create Prometheus metrics for process management
- [ ] Implement telemetry-to-Prometheus bridge
- [ ] Add counter metrics for heartbeats, failures, restarts
- [ ] Add histogram metrics for latency and duration
- [ ] Add gauge metrics for active workers and health status
- [ ] Create example Prometheus configuration
- [ ] Test Prometheus integration with real metrics

#### Acceptance Criteria:
- [ ] Key process management metrics are exported to Prometheus
- [ ] Metrics follow Prometheus naming conventions
- [ ] Metrics include appropriate labels for filtering
- [ ] Example configuration works with standard Prometheus setup
- [ ] Metrics are updated in real-time as events occur
- [ ] Performance impact is minimal

#### Files to Create/Modify:
- `lib/snakepit/metrics/prometheus.ex` (new)
- `examples/monitoring/prometheus.yml` (new)
- `examples/monitoring/grafana_dashboard.json` (new)

---

### Task 4.3: Health Check Endpoints
**Estimated Effort:** 1 day  
**Priority:** P1  
**Dependencies:** Task 4.1

#### Subtasks:
- [ ] Create health check endpoint for process management
- [ ] Implement worker health status aggregation
- [ ] Add heartbeat status to health checks
- [ ] Create readiness and liveness probe endpoints
- [ ] Add detailed health information with worker breakdown
- [ ] Test health endpoints with various worker states
- [ ] Document health check API and responses

#### Acceptance Criteria:
- [ ] `/health/processes` endpoint returns overall process health
- [ ] `/health/workers` endpoint returns per-worker health status
- [ ] Endpoints are suitable for Kubernetes probes
- [ ] Health status includes heartbeat information
- [ ] Responses include actionable information for debugging
- [ ] Endpoints respond quickly (<100ms) even under load

#### Files to Create/Modify:
- `lib/snakepit_web/controllers/health_controller.ex` (new)
- `lib/snakepit_web/router.ex` (modify - add health routes)
- `test/snakepit_web/controllers/health_controller_test.exs` (new)

---

### Task 4.4: Monitoring Dashboards
**Estimated Effort:** 1 day  
**Priority:** P2  
**Dependencies:** Task 4.2

#### Subtasks:
- [ ] Create Grafana dashboard for process management
- [ ] Add panels for heartbeat success rate and latency
- [ ] Add panels for worker lifecycle and restart frequency
- [ ] Add panels for process cleanup and termination metrics
- [ ] Create alerting rules for critical conditions
- [ ] Test dashboard with real monitoring data
- [ ] Document dashboard setup and customization

#### Acceptance Criteria:
- [ ] Grafana dashboard provides comprehensive process visibility
- [ ] Panels show key metrics with appropriate time ranges
- [ ] Dashboard includes alerts for critical conditions
- [ ] Dashboard is easy to import and customize
- [ ] Documentation explains all panels and metrics
- [ ] Dashboard works with standard Grafana/Prometheus setup

#### Files to Create/Modify:
- `examples/monitoring/grafana_process_dashboard.json` (new)
- `examples/monitoring/prometheus_alerts.yml` (new)
- `docs/monitoring/process_management_dashboard.md` (new)

---

## Phase 5: Production Hardening (Week 3)

### Task 5.1: Chaos Testing Integration
**Estimated Effort:** 2 days  
**Priority:** P0  
**Dependencies:** All previous tasks

#### Subtasks:
- [ ] Create comprehensive chaos testing suite
- [ ] Implement BEAM crash simulation tests
- [ ] Add network partition and resource exhaustion tests
- [ ] Create concurrent failure scenario tests
- [ ] Integrate chaos tests with CI/CD pipeline
- [ ] Add performance benchmarking under chaos conditions
- [ ] Document chaos testing procedures and results

#### Acceptance Criteria:
- [ ] Chaos tests cover all major failure scenarios
- [ ] Tests verify zero orphaned processes in all scenarios
- [ ] Tests run automatically in CI/CD pipeline
- [ ] Performance benchmarks show acceptable overhead
- [ ] Test results are clearly documented and tracked
- [ ] Tests can be run manually for debugging

#### Files to Create/Modify:
- `test/chaos/process_management_chaos_test.exs` (new)
- `test/support/chaos_test_helpers.ex` (new)
- `.github/workflows/chaos-tests.yml` (new)
- `scripts/run_chaos_tests.sh` (new)

---

### Task 5.2: Performance Optimization
**Estimated Effort:** 1 day  
**Priority:** P1  
**Dependencies:** Task 5.1

#### Subtasks:
- [ ] Profile heartbeat monitoring overhead
- [ ] Optimize telemetry event emission performance
- [ ] Tune heartbeat intervals for optimal performance
- [ ] Optimize process cleanup and termination speed
- [ ] Benchmark large-scale deployments (1000+ workers)
- [ ] Create performance tuning guidelines
- [ ] Validate performance targets are met

#### Acceptance Criteria:
- [ ] Heartbeat overhead is <1% of worker capacity
- [ ] Telemetry events have <1ms emission overhead
- [ ] Process cleanup completes within 5 seconds
- [ ] System scales to 1000+ workers without degradation
- [ ] Performance tuning guidelines are documented
- [ ] All performance targets are validated with benchmarks

#### Files to Create/Modify:
- `test/performance/process_management_bench.exs` (new)
- `docs/performance/process_management_tuning.md` (new)
- `scripts/benchmark_process_management.exs` (new)

---

### Task 5.3: Documentation and Examples
**Estimated Effort:** 2 days  
**Priority:** P1  
**Dependencies:** All previous tasks

#### Subtasks:
- [ ] Create comprehensive configuration guide
- [ ] Write troubleshooting and debugging guide
- [ ] Create operational runbook for production deployments
- [ ] Write example configurations for common scenarios
- [ ] Create migration guide from existing process management
- [ ] Document monitoring and alerting best practices
- [ ] Create video tutorials and demos

#### Acceptance Criteria:
- [ ] Configuration guide covers all options with examples
- [ ] Troubleshooting guide addresses common issues
- [ ] Operational runbook provides step-by-step procedures
- [ ] Examples work out-of-the-box for common scenarios
- [ ] Migration guide helps users transition smoothly
- [ ] Documentation is clear, accurate, and comprehensive

#### Files to Create/Modify:
- `docs/process_management/configuration.md` (new)
- `docs/process_management/troubleshooting.md` (new)
- `docs/process_management/operations.md` (new)
- `examples/process_management/` (new directory with examples)
- `docs/migration/process_management_migration.md` (new)

---

## Testing Strategy

### Unit Tests (Throughout all phases)
- [ ] HeartbeatMonitor state machine tests
- [ ] Python HeartbeatClient functionality tests
- [ ] Telemetry event emission tests
- [ ] Configuration validation tests
- [ ] Error handling and edge case tests

### Integration Tests (Phase 2-3)
- [ ] End-to-end heartbeat protocol tests
- [ ] Worker crash and restart scenario tests
- [ ] Graceful shutdown behavior tests
- [ ] Cross-platform compatibility tests
- [ ] Watchdog integration tests

### Chaos Tests (Phase 5)
- [ ] BEAM process kill tests (SIGKILL)
- [ ] Network partition simulation tests
- [ ] Resource exhaustion scenario tests
- [ ] Concurrent worker failure tests
- [ ] Long-running stability tests

### Performance Tests (Phase 5)
- [ ] Heartbeat overhead measurement tests
- [ ] Large-scale worker deployment tests
- [ ] Telemetry performance impact tests
- [ ] Memory leak detection tests
- [ ] Latency and throughput benchmarks

## Risk Mitigation

### Technical Risks
- **Platform Compatibility**: Extensive testing on Linux, macOS, Windows
- **Performance Impact**: Continuous benchmarking and optimization
- **Race Conditions**: Careful synchronization and atomic operations
- **Signal Handling**: Robust cross-platform signal handling

### Schedule Risks
- **Dependency Delays**: Parallel development where possible
- **Testing Complexity**: Early and continuous testing approach
- **Integration Issues**: Incremental integration and validation
- **Performance Problems**: Performance testing throughout development

### Quality Risks
- **Insufficient Testing**: Comprehensive test coverage requirements
- **Documentation Gaps**: Documentation written alongside code
- **User Experience**: Regular feedback and usability testing
- **Production Issues**: Extensive chaos testing and validation

## Success Metrics

### Functional Success
- [ ] Zero orphaned processes in 100% of crash scenarios
- [ ] Worker health detection within 10 seconds
- [ ] Automatic worker restart without manual intervention
- [ ] Cross-platform compatibility verified

### Performance Success
- [ ] Heartbeat overhead <1% of worker capacity
- [ ] Process cleanup completes within 5 seconds
- [ ] Telemetry events have <1ms overhead
- [ ] System scales to 1000+ workers

### Operational Success
- [ ] Comprehensive monitoring dashboards available
- [ ] Clear troubleshooting procedures documented
- [ ] Production deployment guides complete
- [ ] Community adoption and positive feedback