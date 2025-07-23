# Snakepit Test Architecture with Supertester Integration

## Overview

This document outlines the comprehensive test architecture for Snakepit, integrating Supertester's OTP-compliant testing patterns to eliminate race conditions, enable true async testing, and ensure deterministic test execution.

## Core Principles

1. **Zero Process.sleep** - All synchronization must be deterministic
2. **Full Isolation** - Every test runs in complete process/ETS isolation
3. **Async by Default** - Tests must run concurrently without conflicts
4. **Test the Public API** - Focus on user-facing behavior, not implementation
5. **Supervision Testing** - Explicitly test fault tolerance and recovery

## Directory Structure

```
test/
├── unit/                           # Isolated component tests
│   ├── bridge/
│   │   ├── session_store_test.exs
│   │   ├── serialization_test.exs
│   │   └── variables_test.exs
│   ├── grpc/
│   │   ├── grpc_worker_test.exs
│   │   ├── bridge_server_test.exs
│   │   └── client_test.exs
│   └── pool/
│       ├── pool_test.exs
│       ├── registry_test.exs
│       └── worker_supervisor_test.exs
├── integration/                    # Cross-component tests
│   ├── grpc_bridge_test.exs
│   ├── pool_lifecycle_test.exs
│   ├── session_workflow_test.exs
│   └── streaming_test.exs
├── performance/                    # Load and benchmark tests
│   ├── pool_saturation_test.exs
│   ├── grpc_throughput_test.exs
│   └── concurrent_sessions_test.exs
├── chaos/                         # Resilience testing
│   ├── worker_crash_test.exs
│   ├── network_failure_test.exs
│   └── supervisor_recovery_test.exs
└── support/
    ├── test_helpers.ex
    ├── grpc_test_adapter.ex
    └── mock_python_server.ex
```

## Supertester Integration

### 1. Base Test Module

```elixir
defmodule Snakepit.TestCase do
  @moduledoc """
  Base test case for all Snakepit tests.
  Provides Supertester integration and common helpers.
  """
  
  defmacro __using__(opts \\ []) do
    quote do
      use ExUnit.Case, async: unquote(Keyword.get(opts, :async, true))
      use Supertester.UnifiedTestFoundation, isolation: :full_isolation
      
      import Supertester.OTPHelpers
      import Supertester.GenServerHelpers
      import Supertester.Assertions
      import Snakepit.TestHelpers
      
      # Ensure clean application state
      setup_all do
        Application.ensure_all_started(:snakepit)
        on_exit(fn -> cleanup_all_sessions() end)
      end
    end
  end
end
```

### 2. gRPC Worker Testing Pattern

```elixir
defmodule Snakepit.GRPCWorkerTest do
  use Snakepit.TestCase
  import Supertester.GenServerHelpers
  
  describe "gRPC worker lifecycle" do
    setup context do
      # Isolated worker with unique port
      port = 50100 + :rand.uniform(1000)
      worker_id = "test_worker_#{context.test}"
      
      {:ok, worker} = setup_isolated_genserver(
        Snakepit.GRPCWorker,
        worker_id,
        adapter: MockGRPCAdapter,
        port: port,
        id: worker_id
      )
      
      # Wait for server ready without sleep
      assert_receive {:grpc_ready, ^port}, 5_000
      
      %{worker: worker, port: port, worker_id: worker_id}
    end
    
    test "worker starts gRPC server and connects", %{worker: worker, port: port} do
      assert_genserver_responsive(worker)
      
      # Verify server is listening
      {:ok, channel} = GRPC.Stub.connect("localhost:#{port}")
      assert channel != nil
    end
    
    test "worker handles commands", %{worker: worker} do
      # Use synchronous call for deterministic behavior
      {:ok, result} = call_with_timeout(worker, {:execute, "ping", %{}, 5_000})
      assert result["status"] == "pong"
    end
    
    test "worker recovers from server crash", %{worker: worker, port: port} do
      # Monitor the worker
      monitor_ref = Process.monitor(worker)
      
      # Simulate server crash
      send(worker, {:EXIT, :simulated_crash})
      
      # Worker should restart
      assert_process_restarted(monitor_ref, worker, 5_000)
      assert_receive {:grpc_ready, ^port}, 5_000
    end
  end
end
```

### 3. Pool Testing Pattern

```elixir
defmodule Snakepit.PoolTest do
  use Snakepit.TestCase
  import Supertester.SupervisorHelpers
  
  describe "pool management" do
    setup do
      pool_name = :"test_pool_#{System.unique_integer()}"
      
      {:ok, pool} = setup_isolated_supervisor(
        Snakepit.Pool,
        pool_name,
        pool_size: 2,
        worker_module: MockWorker
      )
      
      %{pool: pool, pool_name: pool_name}
    end
    
    test "pool starts configured number of workers", %{pool: pool} do
      assert_child_count(pool, 2)
      assert_all_children_alive(pool)
    end
    
    test "pool handles concurrent requests", %{pool_name: pool_name} do
      # Start 10 concurrent tasks
      tasks = for i <- 1..10 do
        Task.async(fn ->
          Snakepit.Pool.execute(pool_name, "echo", %{id: i})
        end)
      end
      
      # All should complete without error
      results = Task.await_many(tasks, 5_000)
      assert length(results) == 10
      assert Enum.all?(results, &match?({:ok, _}, &1))
    end
  end
end
```

### 4. Integration Testing Pattern

```elixir
defmodule Snakepit.GRPCBridgeIntegrationTest do
  use Snakepit.TestCase, async: false
  import Supertester.MessageHelpers
  
  describe "full gRPC bridge integration" do
    setup do
      # Start isolated application instance
      app_name = :"snakepit_test_#{System.unique_integer()}"
      
      # Override configuration for this test
      Application.put_env(app_name, :pooling_enabled, true)
      Application.put_env(app_name, :pool_config, %{pool_size: 2})
      Application.put_env(app_name, :grpc_port, 51000 + :rand.uniform(1000))
      
      {:ok, _} = Application.ensure_all_started(app_name)
      
      on_exit(fn -> Application.stop(app_name) end)
      
      %{app: app_name}
    end
    
    test "end-to-end session workflow", %{app: app} do
      session_id = "integration_#{System.unique_integer()}"
      
      # Initialize session
      {:ok, _} = Snakepit.execute_in_session(session_id, "initialize_session", %{})
      
      # Register variable with proper synchronization
      {:ok, var_id} = Snakepit.execute_in_session(
        session_id,
        "register_variable",
        %{name: "counter", type: "integer", initial_value: 0}
      )
      
      # Concurrent updates
      tasks = for i <- 1..10 do
        Task.async(fn ->
          Snakepit.execute_in_session(
            session_id,
            "set_variable",
            %{name: "counter", value: i}
          )
        end)
      end
      
      Task.await_many(tasks, 5_000)
      
      # Verify final state
      {:ok, var} = Snakepit.execute_in_session(
        session_id,
        "get_variable",
        %{name: "counter"}
      )
      
      assert var["value"] in 1..10
    end
  end
end
```

## Key Testing Patterns

### 1. Synchronization Without Sleep

```elixir
# BAD - Race condition prone
GenServer.cast(worker, :start_server)
Process.sleep(1000)  # Arbitrary wait
assert server_started?()

# GOOD - Deterministic synchronization
ref = monitor_genserver_call(worker, :start_server)
assert_receive {:server_started, port}, 5_000
assert_receive {:DOWN, ^ref, :process, _, :normal}
```

### 2. Port Allocation for gRPC

```elixir
defmodule Snakepit.TestHelpers do
  @base_test_port 52000
  @port_range 1000
  
  def allocate_test_port do
    # Use test number to ensure unique ports
    test_number = Process.get(:test_number, 0)
    Process.put(:test_number, test_number + 1)
    
    @base_test_port + rem(test_number, @port_range)
  end
end
```

### 3. Mock Adapters for Testing

```elixir
defmodule MockGRPCAdapter do
  @behaviour Snakepit.Adapter
  
  def executable_path, do: "echo"
  def script_path, do: "/dev/null"
  def script_args, do: []
  
  def init_grpc_connection(port) do
    # Simulate server startup
    send(self(), {:grpc_ready, port})
    {:ok, %{channel: :mock_channel, port: port}}
  end
  
  def grpc_execute(_conn, "ping", _args, _timeout) do
    {:ok, %{"status" => "pong"}}
  end
end
```

### 4. Chaos Testing Patterns

```elixir
defmodule Snakepit.ChaosTest do
  use Snakepit.TestCase
  import Supertester.ChaosHelpers
  
  test "pool recovers from worker failures" do
    {:ok, pool} = start_supervised_pool(size: 4)
    
    # Inject failures
    inject_random_failures(pool, 
      failure_rate: 0.5,
      failure_types: [:exit, :timeout, :disconnect]
    )
    
    # System should still process requests
    results = for _ <- 1..20 do
      Task.async(fn -> Snakepit.execute("ping", %{}) end)
    end
    |> Task.await_many(10_000)
    
    successful = Enum.count(results, &match?({:ok, _}, &1))
    assert successful >= 15  # At least 75% success rate
  end
end
```

## Supertester Gaps & Enhancements Needed

### What Supertester Provides
- Process isolation mechanisms
- Deterministic synchronization helpers  
- GenServer and Supervisor test utilities
- Message tracing and assertions
- Chaos engineering framework

### What's Missing for Snakepit
1. **gRPC-specific helpers** - Waiting for server ready, port management
2. **Python process helpers** - Starting/stopping external processes
3. **Streaming assertions** - Testing gRPC streams
4. **Session cleanup utilities** - Bulk session management

### Proposed Snakepit Test Extensions

```elixir
defmodule Snakepit.TestHelpers do
  @moduledoc "Snakepit-specific test helpers extending Supertester"
  
  def assert_grpc_server_ready(port, timeout \\ 5_000) do
    assert_receive {:grpc_ready, ^port}, timeout
  end
  
  def with_python_server(port, fun) do
    # Start Python gRPC server
    server = start_python_server(port)
    try do
      assert_grpc_server_ready(port)
      fun.()
    after
      stop_python_server(server)
    end
  end
  
  def assert_streaming_response(stream_ref, expected_chunks) do
    Enum.each(expected_chunks, fn expected ->
      assert_receive {:stream_chunk, ^stream_ref, chunk}, 1_000
      assert chunk == expected
    end)
    assert_receive {:stream_end, ^stream_ref}, 1_000
  end
end
```

## Migration Strategy

### Phase 1: Foundation (Week 1)
1. Add Supertester dependency
2. Create base test case module
3. Set up test directory structure
4. Create mock adapters

### Phase 2: Unit Tests (Week 2)
1. Migrate SessionStore tests
2. Migrate GRPCWorker tests
3. Migrate Pool tests
4. Remove all Process.sleep calls

### Phase 3: Integration Tests (Week 3)
1. Rewrite gRPC bridge tests
2. Add end-to-end workflow tests
3. Add streaming tests
4. Enable async: true everywhere

### Phase 4: Advanced Testing (Week 4)
1. Add performance benchmarks
2. Add chaos tests
3. Add supervisor recovery tests
4. Document testing patterns

## Success Metrics

1. **Zero Process.sleep** in test suite
2. **100% async: true** tests
3. **No test interdependence** - random test order passes
4. **< 30s total test time** with parallelization
5. **Zero flaky tests** over 100 runs

## Conclusion

By integrating Supertester and following these patterns, Snakepit will have:
- Deterministic, fast tests
- True isolation enabling parallel execution
- Proper OTP testing patterns
- Comprehensive coverage including chaos scenarios
- A foundation for continuous deployment confidence

The key is treating tests as first-class citizens that demonstrate proper usage patterns while ensuring reliability through deterministic execution.