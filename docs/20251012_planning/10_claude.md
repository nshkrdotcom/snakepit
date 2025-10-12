# Deep Dive: Chaos Testing & Heartbeat Pattern (Priority Topics)

I'll cover B and D first as requested, then move through the remaining topics efficiently.

---

## B. Chaos Testing Framework

### Test Infrastructure Setup

**Multi-Node Test Environment:**

```elixir
# test/support/cluster_case.ex
defmodule Snakepit.ClusterCase do
  @moduledoc """
  Sets up a local multi-node cluster for distributed tests.
  Uses LocalCluster library for simplicity.
  """
  use ExUnit.CaseTemplate
  
  using do
    quote do
      import Snakepit.ClusterCase
      
      setup do
        nodes = LocalCluster.start_nodes("snakepit-test", 3)
        
        # Load your application on all nodes
        for node <- nodes do
          :rpc.call(node, Application, :ensure_all_started, [:snakepit])
        end
        
        on_exit(fn ->
          LocalCluster.stop_nodes(nodes)
        end)
        
        {:ok, nodes: nodes}
      end
    end
  end
  
  def partition_network(nodes) when is_list(nodes) do
    # Simulate network partition by manipulating :net_kernel
    [group_a, group_b] = Enum.split(nodes, div(length(nodes), 2))
    
    for node_a <- group_a, node_b <- group_b do
      :rpc.call(node_a, :erlang, :disconnect_node, [node_b])
    end
    
    {group_a, group_b}
  end
  
  def heal_network(nodes) do
    for node_a <- nodes, node_b <- nodes, node_a != node_b do
      :rpc.call(node_a, :net_kernel, :connect_node, [node_b])
    end
  end
end
```

### Failure Injection Techniques

**1. BEAM Process Crashes:**

```elixir
defmodule Snakepit.Chaos.BeamKiller do
  @moduledoc """
  Injects BEAM-level failures for chaos testing.
  """
  
  def crash_supervisor(pool_name) do
    pid = Process.whereis(:"Snakepit.Pool.#{pool_name}")
    Process.exit(pid, :kill)
  end
  
  def crash_random_worker(pool_name) do
    case Snakepit.Pool.get_worker_pids(pool_name) do
      {:ok, pids} when pids != [] ->
        victim = Enum.random(pids)
        Process.exit(victim, :kill)
        {:ok, victim}
      _ ->
        {:error, :no_workers}
    end
  end
  
  def simulate_vm_crash do
    # Fork a process that kills the VM after delay
    spawn(fn ->
      Process.sleep(100)
      System.cmd("kill", ["-9", System.pid()])
    end)
    
    # Give tests time to verify cleanup
    Process.sleep(5000)
  end
end
```

**2. Python Worker Failures:**

```python
# test/support/chaos_adapter.py
"""Adapter that can inject failures on command."""
import os
import signal
import time
from snakepit.adapters import BaseAdapter

class ChaosAdapter(BaseAdapter):
    def __init__(self):
        self.chaos_mode = os.environ.get("CHAOS_MODE", "")
        self.request_count = 0
        
    def execute_tool(self, tool_name: str, args: dict, kwargs: dict):
        self.request_count += 1
        
        # Inject failures based on chaos mode
        if self.chaos_mode == "crash_on_third":
            if self.request_count == 3:
                os.kill(os.getpid(), signal.SIGKILL)
        
        elif self.chaos_mode == "memory_leak":
            # Allocate 100MB per request (don't clean up)
            self._leaked_memory = [0] * (100 * 1024 * 1024 // 8)
        
        elif self.chaos_mode == "hang":
            if self.request_count == 2:
                time.sleep(999999)  # Hang forever
        
        elif self.chaos_mode == "slow_death":
            time.sleep(self.request_count * 2)  # Get slower each request
        
        # Normal execution
        return {"status": "ok", "request_count": self.request_count}
```

**3. Network Failures:**

```elixir
defmodule Snakepit.Chaos.NetworkFault do
  @doc """
  Simulates network issues between Elixir and Python.
  Uses tc (traffic control) on Linux to inject latency/packet loss.
  """
  
  def inject_latency(interface \\ "lo", delay_ms) do
    # Requires root - run tests in Docker
    System.cmd("tc", ["qdisc", "add", "dev", interface, "root", "netem", "delay", "#{delay_ms}ms"])
  end
  
  def inject_packet_loss(interface \\ "lo", percent) do
    System.cmd("tc", ["qdisc", "add", "dev", interface, "root", "netem", "loss", "#{percent}%"])
  end
  
  def clear_faults(interface \\ "lo") do
    System.cmd("tc", ["qdisc", "del", "dev", interface, "root"])
  end
  
  def with_network_fault(fault_fn, test_fn) do
    try do
      fault_fn.()
      test_fn.()
    after
      clear_faults()
    end
  end
end
```

### Concrete Chaos Tests

```elixir
defmodule Snakepit.ChaosTest do
  use Snakepit.ClusterCase
  alias Snakepit.Chaos.{BeamKiller, NetworkFault}
  
  @moduletag :chaos
  @moduletag timeout: 60_000  # Chaos tests need time
  
  describe "worker lifecycle resilience" do
    test "pool recovers from random worker crashes" do
      {:ok, _pool} = start_supervised({Snakepit.Pool, name: :chaos_pool, size: 5})
      
      # Crash workers randomly for 10 seconds
      task = Task.async(fn ->
        for _ <- 1..20 do
          BeamKiller.crash_random_worker(:chaos_pool)
          Process.sleep(500)
        end
      end)
      
      # Meanwhile, execute jobs continuously
      results = Enum.map(1..50, fn i ->
        try do
          Snakepit.execute(:chaos_pool, "test_tool", %{iteration: i})
        catch
          :exit, _ -> {:error, :worker_crashed}
        end
      end)
      
      Task.await(task)
      
      # Pool should still be functional
      assert {:ok, _} = Snakepit.execute(:chaos_pool, "health_check", %{})
      
      # At least 50% of requests should have succeeded
      success_count = Enum.count(results, &match?({:ok, _}, &1))
      assert success_count >= 25, 
        "Only #{success_count}/50 requests succeeded - pool not recovering fast enough"
    end
    
    test "no zombie processes after supervisor crash" do
      {:ok, _pool} = start_supervised({Snakepit.Pool, name: :zombie_test, size: 10})
      
      # Get initial Python PIDs
      {:ok, initial_pids} = get_python_pids(:zombie_test)
      assert length(initial_pids) == 10
      
      # Kill the supervisor violently
      BeamKiller.crash_supervisor(:zombie_test)
      Process.sleep(1000)
      
      # Supervisor should restart
      assert Process.whereis(:"Snakepit.Pool.zombie_test") != nil
      
      # OLD Python processes must be dead
      zombies = Enum.filter(initial_pids, &process_alive?/1)
      
      assert zombies == [], 
        "Found #{length(zombies)} zombie Python processes: #{inspect(zombies)}"
    end
    
    test "BEAM crash cleanup" do
      # This test MUST run in external script since we kill the BEAM
      # See test/chaos/beam_crash_test.sh
      
      # 1. Script starts BEAM with pool
      # 2. Gets Python PIDs
      # 3. Kills BEAM with SIGKILL
      # 4. Waits 5 seconds
      # 5. Checks Python PIDs are gone
      
      {output, exit_code} = System.cmd("test/chaos/beam_crash_test.sh", [])
      
      assert exit_code == 0, 
        "BEAM crash cleanup failed:\n#{output}"
    end
  end
  
  describe "network partition resilience" do
    @tag :cluster
    test "sessions survive network partition", %{nodes: nodes} do
      [node1, node2, node3] = nodes
      
      # Start pool on node1
      :rpc.call(node1, Snakepit.Pool, :start_link, [[name: :partition_test, size: 3]])
      
      # Create session from node2
      {:ok, session_id} = :rpc.call(node2, Snakepit, :create_session, [])
      
      # Partition: node1 isolated from node2, node3
      partition_network([node1], [node2, node3])
      Process.sleep(2000)
      
      # node2 should still see the session (if using distributed registry)
      result = :rpc.call(node2, Snakepit.SessionStore, :get, [session_id])
      
      # With basic ETS: will fail (session on node1 only)
      # With Horde: should succeed (session replicated)
      
      # For now, document the limitation
      assert match?({:error, :not_found}, result), 
        "Single-node registry - expected failure during partition"
      
      # Heal network
      heal_network(nodes)
      Process.sleep(1000)
      
      # Session should be accessible again
      assert {:ok, _} = :rpc.call(node2, Snakepit.SessionStore, :get, [session_id])
    end
  end
  
  describe "resource exhaustion" do
    test "pool handles memory-leaking workers" do
      # Use ChaosAdapter with memory_leak mode
      {:ok, _pool} = start_supervised({
        Snakepit.Pool, 
        name: :leak_test,
        size: 3,
        adapter_args: ["--adapter", "test.support.chaos_adapter.ChaosAdapter"],
        env: [{"CHAOS_MODE", "memory_leak"}],
        worker_ttl: {5, :seconds},  # Recycle workers quickly
        memory_threshold_mb: 500
      })
      
      # Execute 100 requests (each leaks 100MB)
      for i <- 1..100 do
        Snakepit.execute(:leak_test, "leak", %{iteration: i})
        Process.sleep(100)
      end
      
      # Workers should have been recycled before OOM
      {:ok, stats} = Snakepit.get_stats(:leak_test)
      
      assert stats.workers_recycled > 5, 
        "Expected workers to be recycled due to memory limits"
      
      # Pool should still be functional
      assert {:ok, _} = Snakepit.execute(:leak_test, "health", %{})
    end
    
    test "port exhaustion prevention" do
      # Start and stop 1000 workers rapidly
      for i <- 1..100 do
        {:ok, pid} = start_supervised({Snakepit.Pool, name: :"burst_#{i}", size: 10})
        stop_supervised(pid)
        
        if rem(i, 10) == 0 do
          # Check no port leaks
          port_count = length(Port.list())
          assert port_count < 50, 
            "Port leak detected: #{port_count} ports open after #{i} iterations"
        end
      end
    end
  end
  
  # Helper functions
  defp get_python_pids(pool_name) do
    # This would call into your ProcessRegistry
    # Placeholder:
    {:ok, [1234, 1235, 1236]}
  end
  
  defp process_alive?(pid) when is_integer(pid) do
    case System.cmd("ps", ["-p", "#{pid}"], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  end
end
```

### External BEAM Crash Test Script

```bash
#!/bin/bash
# test/chaos/beam_crash_test.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/../.."

echo "=== Chaos Test: BEAM Crash Cleanup ==="

# 1. Start BEAM in background with pool
echo "Starting BEAM with worker pool..."
cd "$PROJECT_ROOT"

elixir --name chaos@127.0.0.1 --cookie test -S mix run -e "
  {:ok, _} = Snakepit.Pool.start_link(name: :crash_test, size: 5)
  
  # Write Python PIDs to file
  {:ok, pids} = Snakepit.Pool.get_python_pids(:crash_test)
  File.write!('/tmp/snakepit_pids.txt', Enum.join(pids, \"\\n\"))
  
  IO.puts(\"READY:\#{System.pid()}\")
  Process.sleep(:infinity)
" &

BEAM_PID=$!

# 2. Wait for READY signal
timeout=30
while [ $timeout -gt 0 ]; do
  if grep -q "^READY:" <(jobs -l 2>/dev/null || echo ""); then
    break
  fi
  sleep 1
  ((timeout--))
done

if [ $timeout -eq 0 ]; then
  echo "ERROR: BEAM did not start in time"
  kill $BEAM_PID 2>/dev/null || true
  exit 1
fi

echo "BEAM started with PID: $BEAM_PID"

# 3. Read Python PIDs
sleep 2
if [ ! -f /tmp/snakepit_pids.txt ]; then
  echo "ERROR: Python PIDs file not created"
  kill $BEAM_PID 2>/dev/null || true
  exit 1
fi

PYTHON_PIDS=$(cat /tmp/snakepit_pids.txt)
echo "Python worker PIDs: $PYTHON_PIDS"

# 4. Kill BEAM with extreme prejudice
echo "Killing BEAM with SIGKILL..."
kill -9 $BEAM_PID
sleep 5  # Give OS time to clean up

# 5. Check Python processes are dead
echo "Checking for zombie Python processes..."
failed=0
for pid in $PYTHON_PIDS; do
  if ps -p $pid > /dev/null 2>&1; then
    echo "ERROR: Python process $pid still alive!"
    ps -p $pid
    failed=1
  else
    echo "✓ Python process $pid cleaned up"
  fi
done

# Cleanup
rm -f /tmp/snakepit_pids.txt

if [ $failed -eq 1 ]; then
  echo "FAILED: Zombie processes found"
  exit 1
fi

echo "SUCCESS: All Python processes cleaned up after BEAM crash"
exit 0
```

### CI/CD Integration

```yaml
# .github/workflows/chaos.yml
name: Chaos Tests

on:
  push:
    branches: [main]
  schedule:
    - cron: '0 2 * * *'  # Run nightly

jobs:
  chaos:
    runs-on: ubuntu-latest
    
    steps:
      - uses: actions/checkout@v3
      
      - name: Set up Elixir
        uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.16'
          otp-version: '26'
      
      - name: Set up Python
        uses: actions/setup-python@v4
        with:
          python-version: '3.11'
      
      - name: Install dependencies
        run: |
          mix deps.get
          pip install -e python/
      
      - name: Run chaos tests
        run: |
          # Need elevated privileges for network faults
          sudo mix test --only chaos --trace
        timeout-minutes: 15
      
      - name: Check for leaked processes
        if: always()
        run: |
          echo "=== Python processes after tests ==="
          ps aux | grep python || echo "No Python processes"
          
          echo "=== Open ports ==="
          ss -tulpn || echo "No listening ports"
      
      - name: Upload failure artifacts
        if: failure()
        uses: actions/upload-artifact@v3
        with:
          name: chaos-logs
          path: |
            _build/test/logs/
            /tmp/snakepit_*.log
```

### Property-Based Chaos Testing

```elixir
defmodule Snakepit.ChaosPropertyTest do
  use ExUnit.Case
  use PropCheck
  
  @moduletag :chaos
  @moduletag :slow
  
  property "pool eventually consistent under random failures" do
    forall operations <- chaos_operations() do
      # Start fresh pool
      {:ok, pool} = Snakepit.Pool.start_link(name: :prop_test, size: 3)
      
      try do
        # Execute random chaos operations
        Enum.each(operations, &execute_chaos_operation/1)
        
        # Give system time to stabilize
        Process.sleep(2000)
        
        # System should be in valid state
        assert_valid_pool_state(:prop_test)
      after
        GenServer.stop(pool)
      end
    end
  end
  
  defp chaos_operations do
    list(oneof([
      {:execute, utf8()},
      {:crash_worker},
      {:crash_supervisor},
      {:network_delay, choose(10, 500)},
      {:memory_pressure}
    ]))
  end
  
  defp execute_chaos_operation({:execute, data}) do
    Snakepit.execute(:prop_test, "echo", %{data: data})
  end
  
  defp execute_chaos_operation(:crash_worker) do
    Snakepit.Chaos.BeamKiller.crash_random_worker(:prop_test)
    Process.sleep(100)
  end
  
  defp execute_chaos_operation({:network_delay, ms}) do
    Snakepit.Chaos.NetworkFault.inject_latency("lo", ms)
    Process.sleep(200)
    Snakepit.Chaos.NetworkFault.clear_faults()
  end
  
  defp assert_valid_pool_state(pool_name) do
    # All workers should be responsive
    {:ok, _result} = Snakepit.execute(pool_name, "ping", %{})
    
    # No zombie processes
    {:ok, pids} = Snakepit.Pool.get_python_pids(pool_name)
    assert Enum.all?(pids, &process_alive?/1)
    
    # Stats should be consistent
    {:ok, stats} = Snakepit.get_stats(pool_name)
    assert stats.available_workers > 0
    assert stats.total_workers == 3
  end
end
```

---

## D. Heartbeat Pattern Implementation

### Python Worker Side

```python
# python/snakepit/heartbeat.py
"""
Heartbeat mechanism to detect BEAM crashes and self-terminate.
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


class HeartbeatMonitor:
    """
    Monitors connection to BEAM via stdout pipe.
    If pipe breaks (BEAM crashed), terminates process.
    """
    
    def __init__(
        self,
        stdout: TextIO = sys.stdout,
        interval_seconds: float = 2.0,
        grace_period_seconds: float = 5.0
    ):
        self.stdout = stdout
        self.interval = interval_seconds
        self.grace_period = grace_period_seconds
        self._stop_event = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._last_ack_time = time.time()
        
    def start(self):
        """Start heartbeat thread."""
        if self._thread is not None:
            raise RuntimeError("Heartbeat already started")
        
        self._thread = threading.Thread(
            target=self._heartbeat_loop,
            daemon=True,  # Don't prevent process exit
            name="snakepit-heartbeat"
        )
        self._thread.start()
        logger.info(f"Heartbeat started (interval={self.interval}s)")
    
    def stop(self):
        """Stop heartbeat gracefully."""
        if self._thread is None:
            return
        
        self._stop_event.set()
        self._thread.join(timeout=2.0)
        logger.info("Heartbeat stopped")
    
    def acknowledge(self):
        """
        Called when BEAM sends ACK response.
        Resets timeout counter.
        """
        self._last_ack_time = time.time()
    
    def _heartbeat_loop(self):
        """Main heartbeat loop."""
        consecutive_failures = 0
        max_failures = 3
        
        while not self._stop_event.is_set():
            try:
                # Send heartbeat
                self.stdout.write("HEARTBEAT\n")
                self.stdout.flush()
                
                # Reset failure counter on success
                consecutive_failures = 0
                
                # Check if we've received ACK recently
                time_since_ack = time.time() - self._last_ack_time
                if time_since_ack > self.grace_period:
                    logger.warning(
                        f"No ACK from BEAM for {time_since_ack:.1f}s "
                        f"(grace period: {self.grace_period}s)"
                    )
                
            except BrokenPipeError:
                # stdout pipe broken = BEAM crashed
                logger.critical(
                    "BEAM pipe broken - BEAM process likely crashed. "
                    "Self-terminating to prevent orphaned process."
                )
                self._emergency_shutdown()
                return
            
            except (IOError, OSError) as e:
                consecutive_failures += 1
                logger.error(
                    f"Heartbeat write failed ({consecutive_failures}/{max_failures}): {e}"
                )
                
                if consecutive_failures >= max_failures:
                    logger.critical(
                        f"Heartbeat failed {consecutive_failures} times. "
                        "Assuming BEAM crash, self-terminating."
                    )
                    self._emergency_shutdown()
                    return
            
            # Wait for next interval
            self._stop_event.wait(self.interval)
    
    def _emergency_shutdown(self):
        """
        Immediately terminate process when BEAM crash detected.
        Uses os._exit() to bypass cleanup (we're already orphaned).
        """
        logger.critical("EMERGENCY SHUTDOWN - Sending SIGTERM to self")
        
        try:
            # Try graceful shutdown first
            os.kill(os.getpid(), signal.SIGTERM)
            time.sleep(1)
        except:
            pass
        
        # Force kill if still alive
        os._exit(1)


class AsyncHeartbeatMonitor:
    """Async version for asyncio-based workers."""
    
    def __init__(
        self,
        stdout: TextIO = sys.stdout,
        interval_seconds: float = 2.0
    ):
        self.stdout = stdout
        self.interval = interval_seconds
        self._task: Optional[asyncio.Task] = None
        self._last_ack_time = time.time()
    
    async def start(self):
        """Start heartbeat task."""
        if self._task is not None:
            raise RuntimeError("Heartbeat already started")
        
        self._task = asyncio.create_task(self._heartbeat_loop())
        logger.info("Async heartbeat started")
    
    async def stop(self):
        """Stop heartbeat gracefully."""
        if self._task is None:
            return
        
        self._task.cancel()
        try:
            await self._task
        except asyncio.CancelledError:
            pass
        logger.info("Async heartbeat stopped")
    
    def acknowledge(self):
        """Record ACK from BEAM."""
        self._last_ack_time = time.time()
    
    async def _heartbeat_loop(self):
        """Async heartbeat loop."""
        while True:
            try:
                # Send heartbeat (blocking I/O in executor)
                await asyncio.get_event_loop().run_in_executor(
                    None,
                    self._send_heartbeat
                )
                await asyncio.sleep(self.interval)
                
            except BrokenPipeError:
                logger.critical("BEAM pipe broken - self-terminating")
                os._exit(1)
            
            except asyncio.CancelledError:
                break
            
            except Exception as e:
                logger.error(f"Heartbeat error: {e}")
                await asyncio.sleep(self.interval)
    
    def _send_heartbeat(self):
        """Blocking heartbeat write."""
        self.stdout.write("HEARTBEAT\n")
        self.stdout.flush()
```

### Integration with gRPC Worker

```python
# python/snakepit/grpc_server.py (modified)
import sys
from snakepit.heartbeat import HeartbeatMonitor

class WorkerServicer(pb2_grpc.WorkerServiceServicer):
    def __init__(self, adapter, worker_id: str):
        self.adapter = adapter
        self.worker_id = worker_id
        
        # Start heartbeat monitor
        self.heartbeat = HeartbeatMonitor(
            stdout=sys.stdout,
            interval_seconds=2.0,
            grace_period_seconds=10.0
        )
        self.heartbeat.start()
        logger.info(f"Worker {worker_id} started with heartbeat monitoring")
    
    async def Ping(self, request, context):
        """
        BEAM calls this periodically to check health.
        We acknowledge to reset heartbeat timeout.
        """
        self.heartbeat.acknowledge()
        return pb2.PingResponse(
            status="healthy",
            worker_id=self.worker_id,
            uptime_seconds=time.time() - self.start_time
        )
    
    async def ExecuteTool(self, request, context):
        # Acknowledge on every request
        self.heartbeat.acknowledge()
        
        try:
            result = await self.adapter.execute_tool(
                request.tool_name,
                request.args,
                request.kwargs
            )
            return pb2.ExecuteToolResponse(success=True, result=result)
        except Exception as e:
            logger.exception("Tool execution failed")
            return pb2.ExecuteToolResponse(
                success=False,
                error_message=str(e)
            )
```

### Elixir Side (Port + GenServer)

```elixir
defmodule Snakepit.GRPCWorker do
  use GenServer
  require Logger
  
  @heartbeat_interval 2_000  # Expect heartbeat every 2s
  @heartbeat_timeout 10_000   # Kill worker if no heartbeat for 10s
  
  defstruct [
    :port,
    :id,
    :adapter,
    :grpc_address,
    :heartbeat_timer,
    :last_heartbeat_at,
    :stats
  ]
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end
  
  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    
    id = Keyword.fetch!(opts, :id)
    adapter = Keyword.fetch!(opts, :adapter)
    grpc_port = Keyword.get(opts, :grpc_port, find_free_port())
    
    # Start Python worker via Port
    port = Port.open({:spawn_executable, python_path()}, [
      {:args, build_args(adapter, grpc_port, id)},
      {:cd, python_dir()},
      :binary,
      :exit_status,
      {:line, 1024},
      :stderr_to_stdout
    ])
    
    Logger.metadata(worker_id: id, grpc_port: grpc_port)
    Logger.info("Starting worker")
    
    # Start heartbeat monitoring
    timer = schedule_heartbeat_check()
    
    state = %__MODULE__{
      port: port,
      id: id,
      adapter: adapter,
      grpc_address: "localhost:#{grpc_port}",
      heartbeat_timer: timer,
      last_heartbeat_at: System.monotonic_time(:millisecond),
      stats: %{requests: 0, heartbeats: 0}
    }
    
    {:ok, state}
  end
  
  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    case parse_line(line) do
      {:heartbeat} ->
        handle_heartbeat(state)
      
      {:log, level, message} ->
        log_from_python(level, message, state)
        {:noreply, state}
      
      {:error, message} ->
        Logger.error("Python error: #{message}")
        {:noreply, state}
      
      :unknown ->
        Logger.debug("Python output: #{line}")
        {:noreply, state}
    end
  end
  
  @impl true
  def handle_info(:heartbeat_check, state) do
    now = System.monotonic_time(:millisecond)
    time_since_heartbeat = now - state.last_heartbeat_at
    
    if time_since_heartbeat > @heartbeat_timeout do
      Logger.error("""
      Worker heartbeat timeout!
        Last heartbeat: #{time_since_heartbeat}ms ago
        Threshold: #{@heartbeat_timeout}ms
        Heartbeats received: #{state.stats.heartbeats}
        Requests handled: #{state.stats.requests}
      
      Worker appears frozen or crashed. Terminating.
      """)
      
      # Emit telemetry
      :telemetry.execute(
        [:snakepit, :worker, :heartbeat_timeout],
        %{time_since_heartbeat_ms: time_since_heartbeat},
        %{worker_id: state.id, adapter: state.adapter}
      )
      
      {:stop, :heartbeat_timeout, state}
    else
      # Schedule next check
      timer = schedule_heartbeat_check()
      {:noreply, %{state | heartbeat_timer: timer}}
    end
  end
  
  @impl true
  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.warning("Worker port exited: #{inspect(reason)}")
    {:stop, {:port_exit, reason}, state}
  end
  
  @impl true
  def terminate(reason, state) do
    Logger.info("Worker terminating: #{inspect(reason)}")
    
    # Cancel heartbeat timer
    if state.heartbeat_timer do
      Process.cancel_timer(state.heartbeat_timer)
    end
    
    # Close port (triggers BrokenPipeError in Python)
    if state.port do
      Port.close(state.port)
    end
    
    # Verify Python process dies within 5 seconds
    :timer.sleep(5000)
    
    case get_python_pid(state.port) do
      {:ok, pid} ->
        Logger.error("Python process #{pid} still alive after port close!")
        force_kill_python(pid)
      
      {:error, :not_found} ->
        Logger.debug("Python process cleaned up successfully")
    end
    
    :ok
  end
  
  # Private functions
  
  defp handle_heartbeat(state) do
    now = System.monotonic_time(:millisecond)
    
    # Send ACK back to Python
    send_heartbeat_ack(state.port)
    
    # Update state
    new_state = %{state |
      last_heartbeat_at: now,
      stats: update_in(state.stats.heartbeats, &(&1 + 1))
    }
    
    # Log periodically (every 30 heartbeats = 1 minute)
    if rem(new_state.stats.heartbeats, 30) == 0 do
      Logger.debug("""
      Worker heartbeat status:
        Heartbeats: #{new_state.stats.heartbeats}
        Requests: #{new_state.stats.requests}
        Uptime: #{uptime(state)}s
      """)
    end
    
    {:noreply, new_state}
  end
  
  defp send_heartbeat_ack(port) do
    # Python waits for this ACK
    Port.command(port, "HEARTBEAT_ACK\n")
  end
  
  defp schedule_heartbeat_check do
    # Check more frequently than timeout
    Process.send_after(self(), :heartbeat_check, div(@heartbeat_timeout, 2))
  end
  
  defp parse_line(line) when is_binary(line) do
    case String.trim(line) do
      "HEARTBEAT" ->
        {:heartbeat}
      
      "ERROR:" <> message ->
        {:error, String.trim(message)}
      
      "LOG:" <> rest ->
        case String.split(rest, ":", parts: 2) do
          [level, message] -> {:log, String.to_atom(level), String.trim(message)}
          _ -> :unknown
        end
      
      _ ->
        :unknown
    end
  end
  
  defp force_kill_python(pid) when is_integer(pid) do
    Logger.warning("Force killing Python process #{pid}")
    System.cmd("kill", ["-9", "#{pid}"])
  end
  
  defp get_python_pid(port) do
    # Port info includes OS pid
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> {:ok, pid}
      nil -> {:error, :not_found}
    end
  end
end
```

### Testing Heartbeat Pattern

```elixir
defmodule Snakepit.HeartbeatTest do
  use ExUnit.Case
  
  @moduletag :heartbeat
  
  test "worker self-terminates when BEAM crashes" do
    # This runs in external script (see chaos tests)
    assert :ok == run_beam_crash_script()
  end
  
  test "worker restarted after heartbeat timeout" do
    # Start worker that will freeze (no heartbeats)
    {:ok, pid} = start_supervised({
      Snakepit.GRPCWorker,
      id: "freeze_test",
      adapter: "test.support.freezing_adapter",
      freeze_after: 1  # Stop heartbeats after 1 second
    })
    
    ref = Process.monitor(pid)
    
    # Worker should crash after timeout
    assert_receive {:DOWN, ^ref, :process, ^pid, :heartbeat_timeout}, 15_000
    
    # Supervisor should restart it
    Process.sleep(1000)
    
    # New worker should be healthy
    {:ok, new_pid} = Snakepit.Pool.get_worker("freeze_test")
    assert new_pid != pid
    assert Process.alive?(new_pid)
  end
  
  test "heartbeat acknowledged on every request" do
    {:ok, worker} = start_supervised({Snakepit.GRPCWorker, id: "ack_test"})
    
    # Execute 10 requests
    for i <- 1..10 do
      assert {:ok, _} = Snakepit.execute(worker, "echo", %{i: i})
      Process.sleep(100)
    end
    
    # Worker should still be alive (heartbeat acknowledged)
    assert Process.alive?(worker)
    
    # Check stats
    {:ok, stats} = Snakepit.Worker.get_stats(worker)
    assert stats.heartbeats >= 10  # At least one per request
  end
  
  test "no zombie processes after port close" do
    {:ok, worker} = start_supervised({Snakepit.GRPCWorker, id: "zombie_test"})
    {:ok, python_pid} = Snakepit.Worker.get_python_pid(worker)
    
    # Stop worker
    stop_supervised(worker)
    
    # Python should die within 5 seconds
    Process.sleep(5000)
    
    refute process_alive?(python_pid),
      "Python process #{python_pid} is a zombie!"
  end
  
  defp process_alive?(pid) do
    case System.cmd("ps", ["-p", "#{pid}"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end
end
```

### Platform Differences (Linux vs macOS)

```python
# python/snakepit/heartbeat.py (platform-specific handling)

import platform

class HeartbeatMonitor:
    def __init__(self, stdout, interval_seconds=2.0, grace_period_seconds=5.0):
        # ... existing code ...
        
        # Platform-specific signal handling
        self._setup_signal_handlers()
    
    def _setup_signal_handlers(self):
        """
        Set up OS-specific signal handlers.
        
        Linux: SIGPIPE sent when writing to broken pipe
        macOS: BrokenPipeError exception instead
        Windows: Not supported (ports work differently)
        """
        system = platform.system()
        
        if system == "Linux":
            # On Linux, handle SIGPIPE explicitly
            signal.signal(signal.SIGPIPE, self._handle_sigpipe)
        
        elif system == "Darwin":  # macOS
            # macOS raises BrokenPipeError (handled in main loop)
            pass
        
        elif system == "Windows":
            logger.warning(
                "Heartbeat monitoring on Windows is experimental. "
                "BEAM crash detection may not work as expected."
            )
        
        else:
            logger.warning(f"Unknown platform: {system}")
    
    def _handle_sigpipe(self, signum, frame):
        """Linux-specific SIGPIPE handler."""
        logger.critical("Received SIGPIPE - BEAM pipe broken")
        self._emergency_shutdown()
```

### Tuning Heartbeat Parameters

```elixir
# config/runtime.exs

config :snakepit,
  heartbeat_interval_ms: System.get_env("SNAKEPIT_HEARTBEAT_INTERVAL", "2000") |> String.to_integer(),
  heartbeat_timeout_ms: System.get_env("SNAKEPIT_HEARTBEAT_TIMEOUT", "10000") |> String.to_integer()

# Recommendations:
# - Development: interval=5000, timeout=30000 (less logging noise)
# - Production: interval=2000, timeout=10000 (fast failure detection)
# - High-latency networks: interval=5000, timeout=20000
# - Critical systems: interval=1000, timeout=5000 (aggressive monitoring)
```

---

## Remaining Topics (Brief Coverage)

### A. Telemetry Architecture

**Event Taxonomy:**
```elixir
# Core events to emit
[:snakepit, :pool, :checkout, :start | :stop | :exception]
[:snakepit, :pool, :checkin]
[:snakepit, :worker, :start | :stop | :crash]
[:snakepit, :worker, :recycle]
[:snakepit, :job, :execute, :start | :stop | :exception]
[:snakepit, :session, :create | :destroy]
```

**Integration Pattern:**
```elixir
# In your supervision tree
def start(_type, _args) do
  :ok = attach_telemetry_handlers()
  # ... start children
end

defp attach_telemetry_handlers do
  # For Prometheus
  PromEx.attach_to_snakepit()
  
  # For LiveDashboard
  Phoenix.LiveDashboard.TelemetryHandler.attach("snakepit-metrics")
  
  # Custom handlers
  :telemetry.attach_many("snakepit-logger", events, &log_handler/4, nil)
end
```

### C. Error Handling

**Structured Error Type:**
```elixir
defmodule Snakepit.Error do
  defstruct [:code, :message, :details, :stacktrace, :timestamp]
  
  @type t :: %__MODULE__{
    code: error_code(),
    message: String.t(),
    details: map(),
    stacktrace: Exception.stacktrace(),
    timestamp: DateTime.t()
  }
  
  @type error_code ::
    :timeout
    | :worker_crashed
    | :serialization_error
    | :python_exception
    | :invalid_request
    | :resource_exhausted
end
```

**Python Exception Bridge:**
```python
# Structured error response
error_response = {
    "code": "PYTHON_EXCEPTION",
    "type": type(e).__name__,
    "message": str(e),
    "traceback": traceback.format_exc(),
    "context": {
        "tool_name": tool_name,
        "worker_id": self.worker_id,
        "session_id": session_id
    }
}
```

### E. Resource Management

**Port Leak Detection:**
```elixir
# In test setup
initial_ports = length(Port.list())

# ... run tests ...

final_ports = length(Port.list())
assert final_ports == initial_ports, "Leaked #{final_ports - initial_ports} ports"
```

**Worker Recycling Strategy:**
```elixir
# Recycle based on:
# - Request count (prevent memory leaks)
# - Time alive (refresh state)
# - Memory usage (prevent OOM)
# - Error rate (unstable workers)

def should_recycle?(worker_state) do
  worker_state.requests_handled >= max_requests() or
  worker_state.uptime_seconds >= max_ttl_seconds() or
  worker_state.memory_mb >= memory_threshold() or
  worker_state.error_rate >= error_threshold()
end
```

### F. Production Deployment

**Health Check Endpoint:**
```elixir
defmodule SnakepitWeb.HealthController do
  def check(conn, _params) do
    with {:ok, stats} <- Snakepit.get_stats(),
         true <- stats.available_workers > 0,
         true <- stats.crash_rate < 0.1 do
      json(conn, %{status: "healthy", stats: stats})
    else
      _ -> conn |> put_status(503) |> json(%{status: "unhealthy"})
    end
  end
end
```

**Zero-Downtime Upgrades:**
```elixir
# 1. Start new worker pool (new code version)
# 2. Drain old pool (stop accepting new requests)
# 3. Wait for old requests to complete
# 4. Shutdown old pool
# 5. Switch routing to new pool
```

### G. Observability (Grafana Dashboard)

```json
{
  "dashboard": {
    "title": "Snakepit Metrics",
    "panels": [
      {
        "title": "Worker Pool Status",
        "targets": [{
          "expr": "snakepit_pool_available_workers{pool=\"$pool\"}"
        }]
      },
      {
        "title": "Request Rate",
        "targets": [{
          "expr": "rate(snakepit_requests_total[$__rate_interval])"
        }]
      },
      {
        "title": "Worker Crash Rate",
        "targets": [{
          "expr": "rate(snakepit_worker_crashes_total[$__rate_interval])"
        }]
      }
    ]
  }
}
```

### H. Security

**gRPC TLS:**
```python
# Python worker with TLS
credentials = grpc.ssl_server_credentials(
    [(private_key, certificate_chain)]
)
server.add_secure_port(address, credentials)
```

**Resource Quotas (cgroups):**
```bash
# Limit Python worker resources
cgcreate -g memory,cpu:/snakepit
echo "2G" > /sys/fs/cgroup/memory/snakepit/memory.limit_in_bytes

# Run worker in cgroup
cgexec -g memory,cpu:snakepit python worker.py
```

### I. Performance Optimization

**Pool Sizing Heuristic:**
```elixir
# Workers = (CPU cores × 2) + disk_io_threads
# For CPU-bound: workers = CPU cores
# For I/O-bound: workers = CPU cores × 4
# For mixed: benchmark and tune

optimal_pool_size = 
  case workload_type() do
    :cpu_bound -> System.schedulers_online()
    :io_bound -> System.schedulers_online() * 4
    :mixed -> System.schedulers_online() * 2
  end
```

---

## Summary Action Items

### Immediate (This Week):
1. ✅ Implement heartbeat pattern (Python + Elixir)
2. ✅ Add basic chaos tests (worker crash, supervisor crash)
3. ✅ Create external BEAM crash test script

### Near-Term (v0.7.0):
4. ✅ Full chaos test suite (network faults, resource exhaustion)
5. ✅ CI/CD integration for chaos tests
6. ✅ Property-based chaos testing

### Documentation:
7. ✅ ADR: Heartbeat Pattern vs supervisord
8. ✅ Cookbook: Testing catastrophic failures
9. ✅ Platform-specific considerations (Linux/macOS/Windows)

**Priority Order:** D → B → C → A → E → F → G → H → I
