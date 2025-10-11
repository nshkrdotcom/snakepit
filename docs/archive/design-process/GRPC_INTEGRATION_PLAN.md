# gRPC Integration Technical Plan

## Executive Summary

This document outlines the remaining work needed to complete the gRPC streaming integration in Snakepit. While all foundational components exist (protocol definitions, worker implementations, Python server), they are not yet connected. This plan provides a step-by-step approach to complete the integration.

## Current State Analysis

### ✅ Completed Components

1. **Protocol Layer**
   - Protocol buffer definitions (`snakepit.proto`)
   - Generated Python server code
   - Message types for streaming and sessions

2. **Python gRPC Server**
   - Full server implementation (`grpc_bridge.py`)
   - Streaming handlers for ML inference, data processing
   - Integration with existing command handlers

3. **Elixir Framework**
   - GRPCWorker GenServer implementation
   - GRPCPython adapter with proper interface
   - Streaming API design with callbacks

### ❌ Missing Integration Points

1. **Worker Type Selection**
   - Pool manager always creates stdin/stdout workers
   - No logic to instantiate GRPCWorker based on adapter

2. **gRPC Client Implementation**
   - Adapter contains only placeholder functions
   - No generated Elixir client code
   - Missing actual GRPC.Stub implementation

3. **Public API**
   - Streaming functions not exposed in main Snakepit module
   - No routing logic for streaming requests

4. **Protocol Negotiation**
   - Current negotiation assumes stdin/stdout
   - No gRPC-specific initialization

## Integration Architecture

### Component Interaction Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        Snakepit Public API                       │
│  execute/3  execute_stream/4  execute_in_session/4             │
└────────────────────────┬────────────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────────────┐
│                          Pool Manager                            │
│  - Adapter detection logic                                       │
│  - Worker type selection                                         │
│  - Request routing (standard vs streaming)                       │
└────────────────────────┬────────────────────────────────────────┘
                         │
        ┌────────────────┴────────────────┐
        │                                 │
┌───────▼──────────┐           ┌─────────▼──────────┐
│ Standard Worker  │           │   gRPC Worker      │
│ (stdin/stdout)   │           │ (HTTP/2 + Proto)   │
└───────┬──────────┘           └─────────┬──────────┘
        │                                 │
┌───────▼──────────┐           ┌─────────▼──────────┐
│ Python Process   │           │ gRPC Server        │
│ (Port)           │           │ (localhost:port)   │
└──────────────────┘           └────────────────────┘
```

### Request Flow Comparison

#### Current Flow (stdin/stdout)
```elixir
Snakepit.execute("command", %{args})
  → Pool.execute/3
    → Pool.get_available_worker()
    → Worker.execute(worker_pid, command, args)
      → Port.command(port, encoded_request)
      ← Port message (encoded_response)
    ← {:ok, decoded_response}
```

#### Target Flow (gRPC)
```elixir
Snakepit.execute("command", %{args})
  → Pool.execute/3
    → Pool.get_available_worker()
    → [NEW] Check worker type
    → GRPCWorker.execute(worker_pid, command, args)
      → GRPC.Stub.call(channel, :execute, request)
      ← {:ok, %ExecuteResponse{}}
    ← {:ok, result}

Snakepit.execute_stream("command", %{args}, callback)
  → Pool.execute_stream/4
    → Pool.get_available_worker()
    → GRPCWorker.execute_stream(worker_pid, command, args, callback)
      → GRPC.Stub.stream(channel, :execute_stream, request)
      → Stream.each(response_stream, callback)
    ← :ok
```

## Implementation Plan

### Phase 1: Elixir gRPC Client Setup (2-3 hours)

#### 1.1 Generate Elixir Client Code

Create protobuf generation for Elixir:

```bash
# Install protoc-gen-elixir
mix escript.install hex protobuf

# Update Makefile
proto-elixir: $(PROTO_FILE)
	@mkdir -p $(ELIXIR_OUT_DIR)
	protoc \
		--proto_path=$(PROTO_DIR) \
		--elixir_out=$(ELIXIR_OUT_DIR) \
		--elixir_opt=package_prefix=Snakepit.Grpc \
		$(PROTO_FILE)
	protoc \
		--proto_path=$(PROTO_DIR) \
		--elixir_out=plugins=grpc:$(ELIXIR_OUT_DIR) \
		--elixir_opt=package_prefix=Snakepit.Grpc \
		$(PROTO_FILE)
```

#### 1.2 Create gRPC Client Module

```elixir
# lib/snakepit/grpc/client.ex
defmodule Snakepit.GRPC.Client do
  @moduledoc """
  gRPC client wrapper for Snakepit bridge communication.
  """
  
  alias Snakepit.Grpc.{
    SnakepitBridge.Stub,
    ExecuteRequest,
    ExecuteResponse,
    SessionRequest,
    StreamResponse
  }
  
  def connect(host, port) do
    GRPC.Stub.connect("#{host}:#{port}")
  end
  
  def execute(channel, command, args, timeout \\ 30_000) do
    request = ExecuteRequest.new(
      command: command,
      args: encode_args(args),
      timeout_ms: timeout,
      request_id: generate_request_id()
    )
    
    case Stub.execute(channel, request) do
      {:ok, %ExecuteResponse{success: true} = response} ->
        {:ok, decode_result(response.result)}
      {:ok, %ExecuteResponse{success: false, error: error}} ->
        {:error, error}
      {:error, reason} ->
        {:error, reason}
    end
  end
  
  def execute_stream(channel, command, args, callback, timeout \\ 300_000) do
    request = ExecuteRequest.new(
      command: command,
      args: encode_args(args),
      timeout_ms: timeout,
      request_id: generate_request_id()
    )
    
    stream = Stub.execute_stream(channel, request)
    
    stream
    |> Stream.each(fn
      {:ok, %StreamResponse{} = chunk} ->
        decoded = decode_result(chunk.chunk)
        callback.(Map.put(decoded, "is_final", chunk.is_final))
      {:error, reason} ->
        callback.(%{"error" => inspect(reason), "is_final" => true})
    end)
    |> Stream.run()
  end
  
  defp encode_args(args) when is_map(args) do
    Map.new(args, fn {k, v} ->
      {to_string(k), encode_value(v)}
    end)
  end
  
  defp encode_value(v) when is_binary(v), do: v
  defp encode_value(v), do: Jason.encode!(v)
  
  defp decode_result(result) when is_map(result) do
    Map.new(result, fn {k, v} ->
      {k, decode_value(v)}
    end)
  end
  
  defp decode_value(v) do
    case Jason.decode(v) do
      {:ok, decoded} -> decoded
      _ -> v  # Keep as binary if not JSON
    end
  end
  
  defp generate_request_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
```

### Phase 2: Update Adapter Implementation (1-2 hours)

#### 2.1 Complete gRPC Adapter

```elixir
# lib/snakepit/adapters/grpc_python.ex
defmodule Snakepit.Adapters.GRPCPython do
  # ... existing code ...
  
  @doc """
  Initialize gRPC connection for the worker.
  Called by GRPCWorker during initialization.
  """
  def init_grpc_connection(port) do
    case Snakepit.GRPC.Client.connect("127.0.0.1", port) do
      {:ok, channel} -> 
        {:ok, %{channel: channel, port: port}}
      {:error, reason} ->
        {:error, reason}
    end
  end
  
  @doc """
  Execute a command via gRPC.
  """
  def grpc_execute(connection, command, args, timeout \\ 30_000) do
    Snakepit.GRPC.Client.execute(connection.channel, command, args, timeout)
  end
  
  @doc """
  Execute a streaming command via gRPC.
  """
  def grpc_execute_stream(connection, command, args, callback_fn, timeout \\ 300_000) do
    Snakepit.GRPC.Client.execute_stream(
      connection.channel, 
      command, 
      args, 
      callback_fn, 
      timeout
    )
  end
  
  @doc """
  Check if this adapter uses gRPC.
  """
  def uses_grpc?, do: true
  
  # Remove placeholder implementations
  # Remove make_grpc_call, make_grpc_stream_call, etc.
end
```

### Phase 3: Pool Manager Integration (2-3 hours)

#### 3.1 Update Pool Manager

```elixir
# lib/snakepit/pool/pool.ex
defmodule Snakepit.Pool do
  # ... existing code ...
  
  @doc """
  Execute a streaming command with callback.
  """
  def execute_stream(command, args, callback, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 300_000)
    
    with {:ok, worker} <- get_available_worker(opts),
         :ok <- execute_on_worker_stream(worker, command, args, callback, timeout) do
      :ok
    end
  end
  
  defp start_workers_concurrently(count, startup_timeout) do
    adapter = Application.get_env(:snakepit, :adapter_module)
    worker_module = determine_worker_module(adapter)
    
    Logger.info("🚀 Starting concurrent initialization of #{count} workers...")
    Logger.info("📦 Using worker type: #{inspect(worker_module)}")
    
    # ... rest of existing concurrent start logic ...
    # but use worker_module instead of hardcoded Worker
  end
  
  defp determine_worker_module(adapter) do
    if function_exported?(adapter, :uses_grpc?, 0) and adapter.uses_grpc?() do
      Snakepit.GRPCWorker
    else
      Snakepit.Pool.Worker
    end
  end
  
  defp execute_on_worker(worker_pid, command, args, timeout) do
    # Check worker type and delegate appropriately
    case Process.info(worker_pid, :registered_name) do
      {:registered_name, name} when is_atom(name) ->
        module_name = name |> Atom.to_string() |> String.split(".") |> List.first()
        
        case module_name do
          "Elixir.Snakepit.GRPCWorker" ->
            Snakepit.GRPCWorker.execute(worker_pid, command, args, timeout)
          _ ->
            Snakepit.Pool.Worker.execute(worker_pid, command, args, timeout)
        end
      _ ->
        # Default to standard worker
        Snakepit.Pool.Worker.execute(worker_pid, command, args, timeout)
    end
  end
  
  defp execute_on_worker_stream(worker_pid, command, args, callback, timeout) do
    # Only GRPCWorker supports streaming
    Snakepit.GRPCWorker.execute_stream(worker_pid, command, args, callback, timeout)
  end
end
```

#### 3.2 Update Worker Supervisor

```elixir
# lib/snakepit/pool/worker_supervisor.ex
defmodule Snakepit.Pool.WorkerSupervisor do
  # ... existing code ...
  
  def start_worker(worker_id) do
    adapter = Application.get_env(:snakepit, :adapter_module)
    worker_module = determine_worker_module(adapter)
    
    child_spec = {worker_module, [id: worker_id, adapter: adapter]}
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end
  
  defp determine_worker_module(adapter) do
    if function_exported?(adapter, :uses_grpc?, 0) and adapter.uses_grpc?() do
      Snakepit.GRPCWorker
    else
      Snakepit.Pool.Worker
    end
  end
end
```

### Phase 4: Update Public API (1 hour)

#### 4.1 Expose Streaming Functions

```elixir
# lib/snakepit.ex
defmodule Snakepit do
  # ... existing code ...
  
  @doc """
  Execute a command with streaming results.
  
  The callback function is called for each chunk received from the stream.
  
  ## Examples
  
      Snakepit.execute_stream("batch_inference", %{
        items: ["img1.jpg", "img2.jpg"]
      }, fn chunk ->
        IO.puts("Processed: \#{chunk["item"]}")
      end)
  """
  @spec execute_stream(String.t(), map(), function(), keyword()) :: :ok | {:error, term()}
  def execute_stream(command, args \\ %{}, callback, opts \\ []) do
    ensure_started!()
    
    adapter = Application.get_env(:snakepit, :adapter_module)
    unless function_exported?(adapter, :uses_grpc?, 0) and adapter.uses_grpc?() do
      {:error, :streaming_not_supported}
    else
      Snakepit.Pool.execute_stream(command, args, callback, opts)
    end
  end
  
  @doc """
  Execute a command in a session with streaming results.
  """
  @spec execute_in_session_stream(String.t(), String.t(), map(), function(), keyword()) :: 
    :ok | {:error, term()}
  def execute_in_session_stream(session_id, command, args \\ %{}, callback, opts \\ []) do
    ensure_started!()
    
    adapter = Application.get_env(:snakepit, :adapter_module)
    unless function_exported?(adapter, :uses_grpc?, 0) and adapter.uses_grpc?() do
      {:error, :streaming_not_supported}
    else
      # Add session_id to args
      args_with_session = Map.put(args, :__session_id__, session_id)
      Snakepit.Pool.execute_stream(command, args_with_session, callback, opts)
    end
  end
end
```

### Phase 5: Update GRPCWorker (1 hour)

#### 5.1 Fix Initialization and Connection

```elixir
# lib/snakepit/grpc_worker.ex
defmodule Snakepit.GRPCWorker do
  # ... existing code ...
  
  @impl true
  def init(opts) do
    adapter = Keyword.fetch!(opts, :adapter)
    
    # Start external gRPC server process
    port = adapter.get_port()
    
    case start_grpc_server(adapter, port) do
      {:ok, server_pid} ->
        # Wait for server to start
        Process.sleep(2000)
        
        # Initialize gRPC connection
        case adapter.init_grpc_connection(port) do
          {:ok, connection} ->
            # Schedule health checks
            health_ref = schedule_health_check()
            
            state = %{
              adapter: adapter,
              connection: connection,
              server_pid: server_pid,
              health_check_ref: health_ref,
              stats: initial_stats()
            }
            
            Logger.info("✅ gRPC worker initialized on port #{port}")
            {:ok, state}
            
          {:error, reason} ->
            Logger.error("Failed to connect to gRPC server: #{reason}")
            {:stop, {:grpc_connection_failed, reason}}
        end
        
      {:error, reason} ->
        Logger.error("Failed to start gRPC server: #{reason}")
        {:stop, {:grpc_server_failed, reason}}
    end
  end
  
  defp start_grpc_server(adapter, port) do
    executable = adapter.executable_path()
    script = adapter.script_path()
    args = ["--port", to_string(port)]
    
    port_opts = [
      :binary,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      args: args
    ]
    
    port = Port.open({:spawn_executable, executable}, port_opts)
    {:ok, port}
  end
  
  @impl true
  def handle_call({:execute, command, args, timeout}, _from, state) do
    result = state.adapter.grpc_execute(state.connection, command, args, timeout)
    new_state = update_stats(state, result)
    {:reply, result, new_state}
  end
  
  @impl true
  def handle_call({:execute_stream, command, args, callback, timeout}, _from, state) do
    result = state.adapter.grpc_execute_stream(
      state.connection, 
      command, 
      args, 
      callback, 
      timeout
    )
    new_state = update_stats(state, result)
    {:reply, result, new_state}
  end
end
```

## Testing Strategy

### Phase 1: Unit Tests

```elixir
# test/snakepit/grpc_client_test.exs
defmodule Snakepit.GRPC.ClientTest do
  use ExUnit.Case
  
  describe "argument encoding" do
    test "encodes simple values as JSON" do
      args = %{a: 1, b: "test", c: [1, 2, 3]}
      encoded = Snakepit.GRPC.Client.encode_args(args)
      
      assert encoded["a"] == "1"
      assert encoded["b"] == "test"
      assert encoded["c"] == "[1,2,3]"
    end
    
    test "preserves binary data" do
      binary = <<1, 2, 3, 4, 5>>
      args = %{data: binary}
      encoded = Snakepit.GRPC.Client.encode_args(args)
      
      assert encoded["data"] == binary
    end
  end
end
```

### Phase 2: Integration Tests

```elixir
# test/snakepit/grpc_integration_test.exs
defmodule Snakepit.GRPCIntegrationTest do
  use ExUnit.Case
  
  setup do
    # Configure gRPC adapter
    Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
    Application.put_env(:snakepit, :pool_config, %{pool_size: 1})
    
    {:ok, _} = Application.ensure_all_started(:snakepit)
    :ok
  end
  
  test "basic gRPC execution" do
    assert {:ok, result} = Snakepit.execute("ping", %{})
    assert result["status"] == "ok"
  end
  
  test "streaming execution" do
    chunks = []
    
    assert :ok = Snakepit.execute_stream("ping_stream", %{count: 3}, fn chunk ->
      chunks = [chunk | chunks]
    end)
    
    assert length(chunks) == 3
    assert List.last(chunks)["is_final"] == true
  end
end
```

### Phase 3: Performance Tests

```elixir
# bench/grpc_vs_stdin_benchmark.exs
Benchee.run(%{
  "stdin/stdout" => fn ->
    Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GenericPythonV2)
    Snakepit.execute("echo", %{data: :crypto.strong_rand_bytes(1024)})
  end,
  "gRPC" => fn ->
    Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
    Snakepit.execute("echo", %{data: :crypto.strong_rand_bytes(1024)})
  end
})
```

## Deployment Considerations

### Configuration

```elixir
# config/config.exs
config :snakepit,
  # Enable gRPC for specific environments
  adapter_module: 
    case Mix.env() do
      :prod -> Snakepit.Adapters.GRPCPython
      _ -> Snakepit.Adapters.GenericPythonV2
    end,
  
  # gRPC-specific settings
  grpc_config: %{
    base_port: System.get_env("GRPC_BASE_PORT", "50051") |> String.to_integer(),
    port_range: 100,
    server_startup_timeout: 10_000
  }
```

### Monitoring

```elixir
# Add telemetry events for gRPC operations
:telemetry.execute(
  [:snakepit, :grpc, :request],
  %{duration: duration},
  %{command: command, streaming: streaming?}
)
```

### Graceful Degradation

```elixir
# Fallback strategy if gRPC unavailable
defmodule Snakepit.AdapterFallback do
  def execute_with_fallback(command, args, opts \\ []) do
    primary = Application.get_env(:snakepit, :adapter_module)
    fallback = Application.get_env(:snakepit, :fallback_adapter)
    
    case Snakepit.execute(command, args, opts) do
      {:error, :grpc_unavailable} when fallback != nil ->
        with_adapter(fallback, fn ->
          Snakepit.execute(command, args, opts)
        end)
      result ->
        result
    end
  end
end
```

## Timeline and Effort Estimate

| Phase | Description | Effort | Dependencies |
|-------|-------------|--------|--------------|
| 1 | Elixir gRPC Client Setup | 2-3 hours | protoc-gen-elixir |
| 2 | Update Adapter Implementation | 1-2 hours | Phase 1 |
| 3 | Pool Manager Integration | 2-3 hours | Phase 2 |
| 4 | Update Public API | 1 hour | Phase 3 |
| 5 | Update GRPCWorker | 1 hour | Phases 1-4 |
| 6 | Testing | 2-3 hours | All phases |
| 7 | Documentation | 1 hour | All phases |

**Total Estimate**: 10-15 hours of focused development

## Risk Mitigation

1. **Backward Compatibility**
   - Keep existing stdin/stdout workers functional
   - Use adapter pattern to switch between implementations
   - Gradual rollout with feature flags

2. **Performance Regression**
   - Benchmark before/after integration
   - Monitor latency and throughput
   - Have fallback mechanism ready

3. **Debugging Complexity**
   - Add comprehensive logging at each layer
   - Include request IDs for tracing
   - Implement health checks and diagnostics

## Success Criteria

1. **Functional Requirements**
   - [ ] All existing tests pass with gRPC adapter
   - [ ] Streaming API works for all example use cases
   - [ ] Session management works over gRPC
   - [ ] Health checks report accurate status

2. **Performance Requirements**
   - [ ] First-result latency < 100ms for streaming
   - [ ] No memory leaks during long streams
   - [ ] Concurrent stream handling works correctly
   - [ ] CPU usage comparable to stdin/stdout

3. **Operational Requirements**
   - [ ] Clear error messages for connection failures
   - [ ] Graceful degradation when gRPC unavailable
   - [ ] Monitoring and metrics available
   - [ ] Documentation complete and accurate

## Conclusion

The gRPC integration is well-architected with all foundational pieces in place. The remaining work is primarily "plumbing" - connecting the existing components through the pool manager and exposing the streaming API. With 10-15 hours of focused development, Snakepit will have full gRPC streaming capabilities while maintaining backward compatibility with existing adapters.