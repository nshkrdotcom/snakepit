# Design Document

## Architecture Overview

The Robust Process Management system implements a multi-layered approach to ensure zero orphaned processes and comprehensive health monitoring:

1. **Heartbeat Layer**: Bidirectional health monitoring between BEAM and Python
2. **Self-Termination Layer**: Python workers detect BEAM failures and exit cleanly  
3. **Watchdog Layer**: Optional external monitor for paranoid scenarios
4. **Telemetry Layer**: Comprehensive observability of all process events

## Detailed Component Design

### 1. HeartbeatMonitor (Elixir GenServer)

```elixir
defmodule Snakepit.HeartbeatMonitor do
  @moduledoc """
  Monitors worker health through bidirectional heartbeat protocol.
  
  Responsibilities:
  - Send periodic PING messages to workers
  - Track PONG responses and detect timeouts
  - Trigger worker restarts on health failures
  - Emit telemetry for all heartbeat events
  """
  
  use GenServer
  require Logger
  
  @default_ping_interval 2_000      # 2 seconds
  @default_timeout_threshold 10_000  # 10 seconds
  @max_missed_heartbeats 3
  
  defstruct [
    :worker_pid,
    :worker_id, 
    :ping_interval,
    :timeout_threshold,
    :ping_timer,
    :timeout_timer,
    :last_pong_time,
    :missed_heartbeats,
    :stats
  ]
  
  ## Public API
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end
  
  def get_health_status(monitor_pid) do
    GenServer.call(monitor_pid, :get_health_status)
  end
  
  def force_ping(monitor_pid) do
    GenServer.cast(monitor_pid, :force_ping)
  end
  
  ## GenServer Implementation
  
  @impl true
  def init(opts) do
    worker_pid = Keyword.fetch!(opts, :worker_pid)
    worker_id = Keyword.fetch!(opts, :worker_id)
    ping_interval = Keyword.get(opts, :ping_interval, @default_ping_interval)
    timeout_threshold = Keyword.get(opts, :timeout_threshold, @default_timeout_threshold)
    
    # Monitor the worker process
    Process.monitor(worker_pid)
    
    state = %__MODULE__{
      worker_pid: worker_pid,
      worker_id: worker_id,
      ping_interval: ping_interval,
      timeout_threshold: timeout_threshold,
      last_pong_time: System.monotonic_time(:millisecond),
      missed_heartbeats: 0,
      stats: %{pings_sent: 0, pongs_received: 0, timeouts: 0}
    }
    
    # Start heartbeat cycle
    {:ok, schedule_ping(state)}
  end
  
  @impl true
  def handle_info(:send_ping, state) do
    case send_ping_to_worker(state) do
      :ok ->
        new_state = %{state | 
          stats: update_in(state.stats.pings_sent, &(&1 + 1))
        }
        |> schedule_ping()
        |> schedule_timeout()
        
        emit_telemetry(:ping_sent, new_state)
        {:noreply, new_state}
        
      {:error, reason} ->
        Logger.warning("Failed to send ping to worker #{state.worker_id}: #{inspect(reason)}")
        handle_worker_failure(state, :ping_failed)
    end
  end
  
  @impl true
  def handle_info(:heartbeat_timeout, state) do
    missed = state.missed_heartbeats + 1
    
    if missed >= @max_missed_heartbeats do
      Logger.error("Worker #{state.worker_id} failed heartbeat check (#{missed} missed)")
      handle_worker_failure(state, :heartbeat_timeout)
    else
      Logger.warning("Worker #{state.worker_id} missed heartbeat #{missed}/#{@max_missed_heartbeats}")
      new_state = %{state | missed_heartbeats: missed}
      emit_telemetry(:heartbeat_missed, new_state)
      {:noreply, new_state}
    end
  end
  
  @impl true
  def handle_info({:pong_received, timestamp}, state) do
    now = System.monotonic_time(:millisecond)
    latency = now - timestamp
    
    # Cancel timeout timer
    if state.timeout_timer do
      Process.cancel_timer(state.timeout_timer)
    end
    
    new_state = %{state |
      last_pong_time: now,
      missed_heartbeats: 0,
      timeout_timer: nil,
      stats: update_in(state.stats.pongs_received, &(&1 + 1))
    }
    
    emit_telemetry(:pong_received, new_state, %{latency_ms: latency})
    {:noreply, new_state}
  end
  
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{worker_pid: pid} = state) do
    Logger.info("Worker #{state.worker_id} process terminated: #{inspect(reason)}")
    emit_telemetry(:worker_terminated, state, %{reason: reason})
    {:stop, :normal, state}
  end
  
  ## Private Functions
  
  defp send_ping_to_worker(state) do
    timestamp = System.monotonic_time(:millisecond)
    
    # Send via gRPC or direct message depending on worker type
    case Snakepit.GRPCWorker.send_heartbeat_ping(state.worker_pid, timestamp) do
      :ok -> :ok
      error -> error
    end
  end
  
  defp schedule_ping(state) do
    timer = Process.send_after(self(), :send_ping, state.ping_interval)
    %{state | ping_timer: timer}
  end
  
  defp schedule_timeout(state) do
    timer = Process.send_after(self(), :heartbeat_timeout, state.timeout_threshold)
    %{state | timeout_timer: timer}
  end
  
  defp handle_worker_failure(state, reason) do
    emit_telemetry(:worker_failed, state, %{failure_reason: reason})
    
    # Notify the pool to restart this worker
    Snakepit.Pool.restart_worker(state.worker_id, reason)
    
    {:stop, :normal, state}
  end
  
  defp emit_telemetry(event, state, extra_metadata \\ %{}) do
    :telemetry.execute(
      [:snakepit, :heartbeat, event],
      %{count: 1, timestamp: System.monotonic_time(:millisecond)},
      Map.merge(%{
        worker_id: state.worker_id,
        worker_pid: state.worker_pid,
        missed_heartbeats: state.missed_heartbeats
      }, extra_metadata)
    )
  end
end
```

### 2. Python Heartbeat Client

```python
# priv/python/snakepit_bridge/heartbeat.py
"""
Heartbeat client for monitoring BEAM connection health.
Implements self-termination on BEAM failure detection.
"""

import asyncio
import logging
import os
import signal
import sys
import threading
import time
from typing import Optional, TextIO

logger = logging.getLogger(__name__)

class HeartbeatClient:
    """
    Monitors connection to BEAM and handles self-termination.
    
    Features:
    - Responds to PING messages with PONG
    - Monitors stdout pipe for broken connections
    - Self-terminates on BEAM crash detection
    - Graceful shutdown on SIGTERM
    """
    
    def __init__(self, 
                 stdout: TextIO = sys.stdout,
                 check_interval: float = 1.0,
                 beam_pid: Optional[int] = None):
        self.stdout = stdout
        self.check_interval = check_interval
        self.beam_pid = beam_pid
        self._stop_event = threading.Event()
        self._monitor_thread: Optional[threading.Thread] = None
        self._last_ping_time = time.time()
        self._ping_count = 0
        self._pong_count = 0
        
        # Set up signal handlers
        self._setup_signal_handlers()
        
    def start(self):
        """Start heartbeat monitoring."""
        if self._monitor_thread is not None:
            raise RuntimeError("Heartbeat client already started")
            
        self._monitor_thread = threading.Thread(
            target=self._monitor_loop,
            daemon=True,
            name="heartbeat-monitor"
        )
        self._monitor_thread.start()
        logger.info("Heartbeat client started")
        
    def stop(self):
        """Stop heartbeat monitoring gracefully."""
        if self._monitor_thread is None:
            return
            
        self._stop_event.set()
        self._monitor_thread.join(timeout=2.0)
        logger.info("Heartbeat client stopped")
        
    def handle_ping(self, timestamp: int) -> bool:
        """
        Handle incoming PING message from BEAM.
        
        Args:
            timestamp: Timestamp from BEAM for latency calculation
            
        Returns:
            True if PONG was sent successfully, False otherwise
        """
        try:
            self._last_ping_time = time.time()
            self._ping_count += 1
            
            # Send PONG response
            pong_message = f"PONG:{timestamp}:{int(time.time() * 1000)}\n"
            self.stdout.write(pong_message)
            self.stdout.flush()
            
            self._pong_count += 1
            logger.debug(f"Sent PONG response (ping #{self._ping_count})")
            return True
            
        except BrokenPipeError:
            logger.critical("BEAM pipe broken during PONG - BEAM crashed!")
            self._emergency_shutdown("broken_pipe")
            return False
            
        except (IOError, OSError) as e:
            logger.error(f"Failed to send PONG: {e}")
            return False
            
    def get_stats(self) -> dict:
        """Get heartbeat statistics."""
        return {
            "pings_received": self._ping_count,
            "pongs_sent": self._pong_count,
            "last_ping_time": self._last_ping_time,
            "uptime_seconds": time.time() - self._start_time
        }
        
    def _setup_signal_handlers(self):
        """Set up signal handlers for graceful shutdown."""
        def signal_handler(signum, frame):
            logger.info(f"Received signal {signum}, shutting down gracefully")
            self._graceful_shutdown(f"signal_{signum}")
            
        # Handle SIGTERM gracefully
        signal.signal(signal.SIGTERM, signal_handler)
        
        # Handle SIGINT (Ctrl+C) gracefully  
        signal.signal(signal.SIGINT, signal_handler)
        
        # On Unix systems, handle SIGPIPE
        if hasattr(signal, 'SIGPIPE'):
            signal.signal(signal.SIGPIPE, lambda s, f: self._emergency_shutdown("sigpipe"))
            
    def _monitor_loop(self):
        """Main monitoring loop."""
        self._start_time = time.time()
        
        while not self._stop_event.is_set():
            try:
                # Check if BEAM process still exists (if PID provided)
                if self.beam_pid and not self._is_process_alive(self.beam_pid):
                    logger.critical(f"BEAM process {self.beam_pid} no longer exists!")
                    self._emergency_shutdown("beam_pid_missing")
                    break
                    
                # Check for stale heartbeats (no PING for too long)
                time_since_ping = time.time() - self._last_ping_time
                if time_since_ping > 30:  # 30 seconds without ping
                    logger.warning(f"No PING received for {time_since_ping:.1f}s")
                    
                # Sleep until next check
                self._stop_event.wait(self.check_interval)
                
            except Exception as e:
                logger.error(f"Error in heartbeat monitor loop: {e}")
                self._stop_event.wait(self.check_interval)
                
    def _is_process_alive(self, pid: int) -> bool:
        """Check if a process is still running."""
        try:
            # Send signal 0 to check if process exists
            os.kill(pid, 0)
            return True
        except (OSError, ProcessLookupError):
            return False
            
    def _graceful_shutdown(self, reason: str):
        """Perform graceful shutdown."""
        logger.info(f"Graceful shutdown initiated: {reason}")
        self.stop()
        sys.exit(0)
        
    def _emergency_shutdown(self, reason: str):
        """Perform emergency shutdown when BEAM crash detected."""
        logger.critical(f"EMERGENCY SHUTDOWN: {reason}")
        
        # Try to notify any monitoring systems
        try:
            error_msg = f"EMERGENCY_SHUTDOWN:{reason}:{int(time.time())}\n"
            sys.stderr.write(error_msg)
            sys.stderr.flush()
        except:
            pass  # Best effort
            
        # Force exit immediately
        os._exit(1)

# Integration with gRPC server
class HeartbeatServicer:
    """gRPC servicer for heartbeat protocol."""
    
    def __init__(self, heartbeat_client: HeartbeatClient):
        self.heartbeat_client = heartbeat_client
        
    async def Ping(self, request, context):
        """Handle PING from BEAM."""
        timestamp = request.timestamp
        success = self.heartbeat_client.handle_ping(timestamp)
        
        return PingResponse(
            success=success,
            timestamp=int(time.time() * 1000),
            stats=self.heartbeat_client.get_stats()
        )
```

### 3. Watchdog Process (Shell Script)

```bash
#!/bin/bash
# priv/scripts/watchdog.sh
# Lightweight watchdog process for paranoid scenarios

set -euo pipefail

# Configuration
BEAM_PID="$1"
PYTHON_PID="$2" 
WORKER_ID="${3:-unknown}"
CHECK_INTERVAL="${WATCHDOG_CHECK_INTERVAL:-1}"
GRACE_PERIOD="${WATCHDOG_GRACE_PERIOD:-3}"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WATCHDOG[$WORKER_ID]: $*" >&2
}

# Cleanup function
cleanup() {
    log "Watchdog shutting down"
    exit 0
}

# Signal handlers
trap cleanup TERM INT

log "Starting watchdog for BEAM PID $BEAM_PID, Python PID $PYTHON_PID"

# Main monitoring loop
while true; do
    # Check if BEAM process still exists
    if ! kill -0 "$BEAM_PID" 2>/dev/null; then
        log "BEAM process $BEAM_PID no longer exists - terminating Python worker"
        
        # Try graceful shutdown first
        if kill -0 "$PYTHON_PID" 2>/dev/null; then
            log "Sending SIGTERM to Python PID $PYTHON_PID"
            kill -TERM "$PYTHON_PID" 2>/dev/null || true
            
            # Wait for graceful shutdown
            for i in $(seq 1 "$GRACE_PERIOD"); do
                if ! kill -0 "$PYTHON_PID" 2>/dev/null; then
                    log "Python process terminated gracefully"
                    exit 0
                fi
                sleep 1
            done
            
            # Force kill if still running
            if kill -0 "$PYTHON_PID" 2>/dev/null; then
                log "Python process did not terminate gracefully, sending SIGKILL"
                kill -KILL "$PYTHON_PID" 2>/dev/null || true
                sleep 1
                
                if kill -0 "$PYTHON_PID" 2>/dev/null; then
                    log "ERROR: Python process $PYTHON_PID still running after SIGKILL"
                    exit 1
                else
                    log "Python process terminated with SIGKILL"
                fi
            fi
        else
            log "Python process $PYTHON_PID already terminated"
        fi
        
        exit 0
    fi
    
    # Check if Python process still exists
    if ! kill -0 "$PYTHON_PID" 2>/dev/null; then
        log "Python process $PYTHON_PID terminated - watchdog no longer needed"
        exit 0
    fi
    
    sleep "$CHECK_INTERVAL"
done
```

### 4. Enhanced GRPCWorker Integration

```elixir
defmodule Snakepit.GRPCWorker do
  use GenServer
  require Logger
  
  # Add heartbeat monitoring to existing worker
  defstruct [
    # ... existing fields ...
    :heartbeat_monitor,
    :heartbeat_config,
    :watchdog_pid
  ]
  
  @impl true
  def init(opts) do
    # ... existing init code ...
    
    # Start heartbeat monitoring if enabled
    heartbeat_config = Keyword.get(opts, :heartbeat_config, %{})
    
    state = %__MODULE__{
      # ... existing state ...
      heartbeat_config: heartbeat_config
    }
    
    {:ok, state, {:continue, :start_heartbeat}}
  end
  
  @impl true
  def handle_continue(:start_heartbeat, state) do
    if state.heartbeat_config[:enabled] != false do
      case start_heartbeat_monitor(state) do
        {:ok, monitor_pid} ->
          new_state = %{state | heartbeat_monitor: monitor_pid}
          {:noreply, new_state}
          
        {:error, reason} ->
          Logger.error("Failed to start heartbeat monitor: #{inspect(reason)}")
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end
  
  def send_heartbeat_ping(worker_pid, timestamp) do
    GenServer.call(worker_pid, {:heartbeat_ping, timestamp})
  end
  
  @impl true
  def handle_call({:heartbeat_ping, timestamp}, _from, state) do
    case send_grpc_ping(state, timestamp) do
      {:ok, response} ->
        # Notify heartbeat monitor of successful pong
        if state.heartbeat_monitor do
          send(state.heartbeat_monitor, {:pong_received, timestamp})
        end
        {:reply, :ok, state}
        
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end
  
  defp start_heartbeat_monitor(state) do
    opts = [
      worker_pid: self(),
      worker_id: state.id,
      ping_interval: state.heartbeat_config[:ping_interval] || 2_000,
      timeout_threshold: state.heartbeat_config[:timeout_threshold] || 10_000
    ]
    
    Snakepit.HeartbeatMonitor.start_link(opts)
  end
  
  defp send_grpc_ping(state, timestamp) do
    request = %Snakepit.GRPC.PingRequest{timestamp: timestamp}
    
    case GRPC.Stub.call(state.channel, Snakepit.GRPC.WorkerService.Ping, request) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end
  
  # Optional watchdog process startup
  defp start_watchdog_process(state) do
    if state.heartbeat_config[:watchdog_enabled] do
      beam_pid = System.pid()
      python_pid = get_python_pid(state.port)
      
      watchdog_script = Path.join(:code.priv_dir(:snakepit), "scripts/watchdog.sh")
      
      case System.cmd(watchdog_script, [
        to_string(beam_pid),
        to_string(python_pid), 
        state.id
      ], [:stderr_to_stdout]) do
        {_output, 0} ->
          Logger.info("Watchdog process started for worker #{state.id}")
          :ok
          
        {output, exit_code} ->
          Logger.error("Failed to start watchdog: #{output} (exit: #{exit_code})")
          {:error, :watchdog_failed}
      end
    else
      :ok
    end
  end
end
```

### 5. Telemetry Events Schema

```elixir
defmodule Snakepit.ProcessTelemetry do
  @moduledoc """
  Comprehensive telemetry events for process lifecycle management.
  """
  
  @doc """
  Telemetry events emitted by the process management system:
  
  ## Heartbeat Events
  
  - `[:snakepit, :heartbeat, :ping_sent]`
    - Measurements: `%{count: 1, timestamp: integer()}`
    - Metadata: `%{worker_id: String.t(), worker_pid: pid()}`
    
  - `[:snakepit, :heartbeat, :pong_received]`
    - Measurements: `%{count: 1, latency_ms: integer()}`
    - Metadata: `%{worker_id: String.t(), worker_pid: pid()}`
    
  - `[:snakepit, :heartbeat, :timeout]`
    - Measurements: `%{count: 1, missed_count: integer()}`
    - Metadata: `%{worker_id: String.t(), timeout_threshold_ms: integer()}`
    
  ## Process Lifecycle Events
  
  - `[:snakepit, :process, :started]`
    - Measurements: `%{count: 1, startup_duration_ms: integer()}`
    - Metadata: `%{worker_id: String.t(), python_pid: integer(), beam_pid: integer()}`
    
  - `[:snakepit, :process, :terminated]`
    - Measurements: `%{count: 1, uptime_ms: integer()}`
    - Metadata: `%{worker_id: String.t(), exit_code: integer(), reason: atom()}`
    
  - `[:snakepit, :process, :cleanup_completed]`
    - Measurements: `%{count: 1, cleanup_duration_ms: integer()}`
    - Metadata: `%{worker_id: String.t(), cleanup_method: atom(), success: boolean()}`
    
  ## Watchdog Events
  
  - `[:snakepit, :watchdog, :started]`
    - Measurements: `%{count: 1}`
    - Metadata: `%{worker_id: String.t(), beam_pid: integer(), python_pid: integer()}`
    
  - `[:snakepit, :watchdog, :beam_death_detected]`
    - Measurements: `%{count: 1, detection_time_ms: integer()}`
    - Metadata: `%{worker_id: String.t(), beam_pid: integer()}`
    
  - `[:snakepit, :watchdog, :python_terminated]`
    - Measurements: `%{count: 1, termination_duration_ms: integer()}`
    - Metadata: `%{worker_id: String.t(), method: :sigterm | :sigkill}`
  """
  
  def attach_default_handlers do
    events = [
      [:snakepit, :heartbeat, :ping_sent],
      [:snakepit, :heartbeat, :pong_received], 
      [:snakepit, :heartbeat, :timeout],
      [:snakepit, :process, :started],
      [:snakepit, :process, :terminated],
      [:snakepit, :process, :cleanup_completed],
      [:snakepit, :watchdog, :started],
      [:snakepit, :watchdog, :beam_death_detected],
      [:snakepit, :watchdog, :python_terminated]
    ]
    
    :telemetry.attach_many(
      "snakepit-process-management",
      events,
      &__MODULE__.handle_event/4,
      nil
    )
  end
  
  def handle_event(event, measurements, metadata, _config) do
    # Default handler logs important events
    case event do
      [:snakepit, :heartbeat, :timeout] ->
        Logger.warning("Worker heartbeat timeout", 
          worker_id: metadata.worker_id,
          missed_count: measurements.missed_count
        )
        
      [:snakepit, :process, :terminated] ->
        Logger.info("Worker process terminated",
          worker_id: metadata.worker_id,
          reason: metadata.reason,
          uptime_ms: measurements.uptime_ms
        )
        
      [:snakepit, :watchdog, :beam_death_detected] ->
        Logger.critical("Watchdog detected BEAM death",
          worker_id: metadata.worker_id,
          beam_pid: metadata.beam_pid
        )
        
      _ ->
        Logger.debug("Process management event: #{inspect(event)}")
    end
  end
end
```

## Configuration Schema

```elixir
# Configuration options for robust process management
config :snakepit,
  process_management: %{
    # Heartbeat configuration
    heartbeat: %{
      enabled: true,
      ping_interval_ms: 2_000,
      timeout_threshold_ms: 10_000,
      max_missed_heartbeats: 3
    },
    
    # Watchdog configuration  
    watchdog: %{
      enabled: false,  # Optional, disabled by default
      check_interval_s: 1,
      grace_period_s: 3
    },
    
    # Process cleanup configuration
    cleanup: %{
      graceful_shutdown_timeout_ms: 30_000,
      force_kill_timeout_ms: 5_000,
      use_process_groups: true
    },
    
    # Telemetry configuration
    telemetry: %{
      enabled: true,
      emit_heartbeat_events: true,
      emit_process_events: true,
      emit_watchdog_events: true
    }
  }
```

## Testing Strategy

### Unit Tests
- HeartbeatMonitor state machine
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

## Monitoring and Alerting

### Key Metrics
- Worker heartbeat success rate (target: >99.9%)
- Heartbeat response latency (target: <100ms P95)
- Worker restart frequency (target: <1% per hour)
- Process cleanup duration (target: <5s P95)
- Orphaned process count (target: 0)

### Recommended Alerts
- Heartbeat success rate <99% for 5 minutes
- Heartbeat latency >1s for 2 minutes  
- Worker restart rate >5% for 10 minutes
- Any orphaned processes detected
- Watchdog activations (BEAM death detected)

This design provides a comprehensive, BEAM-native solution for robust process management that eliminates orphaned processes while providing full observability of worker health.