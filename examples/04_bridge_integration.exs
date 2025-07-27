#!/usr/bin/env elixir

# Example 04: Bridge Integration
# 
# This example shows how the SnakepitGRPCBridge.Adapter integrates
# with Snakepit's infrastructure layer, demonstrating the clean
# separation of concerns in the three-layer architecture.

# First, let's create a mock version of the bridge adapter
# (In production, this would be SnakepitGRPCBridge.Adapter)
defmodule MockBridgeAdapter do
  @moduledoc """
  Mock implementation of a bridge adapter showing the integration pattern.
  
  In the real implementation:
  - This would start Python processes with gRPC
  - Communication would use protobuf
  - State would be managed in the bridge layer
  
  This mock simulates the contract without external dependencies.
  """
  
  @behaviour Snakepit.Adapter
  require Logger
  use GenServer
  
  # Adapter Behavior Implementation
  
  @impl Snakepit.Adapter
  def init(config) do
    Logger.info("MockBridge: Initializing with config: #{inspect(config)}")
    
    state = %{
      config: config,
      beam_run_id: generate_beam_run_id(),
      python_path: Keyword.get(config, :python_path, "python3"),
      grpc_port_range: {50000, 50100},
      started_at: DateTime.utc_now()
    }
    
    {:ok, state}
  end
  
  @impl Snakepit.Adapter
  def start_worker(adapter_state, worker_id) do
    Logger.info("MockBridge: Starting worker #{worker_id}")
    
    # In real implementation:
    # 1. Reserve slot in ProcessRegistry
    # 2. Allocate gRPC port
    # 3. Start Python process
    # 4. Establish gRPC connection
    # 5. Register with ProcessRegistry
    
    # For this mock, start a GenServer that simulates a Python worker
    {:ok, pid} = GenServer.start_link(__MODULE__, {adapter_state, worker_id})
    
    # Simulate OS PID tracking (real adapter would get actual OS PID)
    mock_os_pid = :erlang.unique_integer([:positive])
    fingerprint = "#{adapter_state.beam_run_id}_#{worker_id}"
    
    Logger.info("MockBridge: Worker #{worker_id} started with mock OS PID: #{mock_os_pid}")
    
    # In real implementation, this would be:
    # ProcessRegistry.activate_worker(worker_id, pid, os_pid, fingerprint)
    
    {:ok, pid}
  end
  
  @impl Snakepit.Adapter
  def execute(command, args, opts) do
    worker_pid = Keyword.fetch!(opts, :worker_pid)
    timeout = Keyword.get(opts, :timeout, 30_000)
    
    GenServer.call(worker_pid, {:execute, command, args, opts}, timeout)
  end
  
  @impl Snakepit.Adapter
  def terminate(reason, state) do
    Logger.info("MockBridge: Terminating (#{inspect(reason)})")
    Logger.info("MockBridge: Was running for #{DateTime.diff(DateTime.utc_now(), state.started_at)} seconds")
    :ok
  end
  
  @impl Snakepit.Adapter
  def supports_streaming?(), do: true
  
  @impl Snakepit.Adapter
  def execute_stream(command, args, callback, opts) do
    worker_pid = Keyword.fetch!(opts, :worker_pid)
    GenServer.cast(worker_pid, {:stream, command, args, callback})
    :ok
  end
  
  # GenServer Implementation (Mock Python Worker)
  
  def init({adapter_state, worker_id}) do
    state = %{
      worker_id: worker_id,
      adapter_state: adapter_state,
      grpc_port: allocate_port(adapter_state.grpc_port_range),
      sessions: %{},
      tools: %{},
      variables: %{}
    }
    
    {:ok, state}
  end
  
  def handle_call({:execute, command, args, opts}, _from, state) do
    session_id = Keyword.get(opts, :session_id)
    
    result = case command do
      # Session management
      "initialize_session" ->
        new_state = put_in(state.sessions[session_id], %{
          created_at: DateTime.utc_now(),
          variables: %{},
          tools: []
        })
        {{:ok, %{session_id: session_id, status: "initialized"}}, new_state}
      
      # Variable operations (simulating bridge variable system)
      "set_variable" ->
        var_name = Map.fetch!(args, "name")
        var_value = Map.fetch!(args, "value")
        var_type = Map.get(args, "type", "any")
        
        new_state = put_in(state.variables[{session_id, var_name}], %{
          value: var_value,
          type: var_type,
          updated_at: DateTime.utc_now()
        })
        
        {{:ok, %{variable: var_name, set: true}}, new_state}
      
      "get_variable" ->
        var_name = Map.fetch!(args, "name")
        case Map.get(state.variables, {session_id, var_name}) do
          nil -> {{:error, "Variable not found: #{var_name}"}, state}
          var_info -> {{:ok, var_info}, state}
        end
      
      # Tool operations (simulating bidirectional tools)
      "register_tool" ->
        tool_name = Map.fetch!(args, "name")
        tool_spec = Map.get(args, "spec", %{})
        
        new_state = put_in(state.tools[tool_name], %{
          spec: tool_spec,
          registered_at: DateTime.utc_now()
        })
        
        {{:ok, %{tool: tool_name, registered: true}}, new_state}
      
      "execute_tool" ->
        tool_name = Map.fetch!(args, "tool")
        tool_args = Map.get(args, "args", %{})
        
        # Simulate tool execution
        result = %{
          tool: tool_name,
          result: "Mock result for #{tool_name}(#{inspect(tool_args)})",
          executed_at: DateTime.utc_now()
        }
        
        {{:ok, result}, state}
      
      # ML operations (simulating DSPy integration)
      "predict" ->
        signature = Map.get(args, "signature", "input -> output")
        inputs = Map.get(args, "inputs", %{})
        
        # Simulate prediction
        result = %{
          signature: signature,
          inputs: inputs,
          outputs: %{"output" => "Mock prediction result"},
          model: "mock-model",
          latency_ms: :rand.uniform(100)
        }
        
        {{:ok, result}, state}
      
      # Bridge info
      "get_bridge_info" ->
        info = %{
          worker_id: state.worker_id,
          grpc_port: state.grpc_port,
          active_sessions: map_size(state.sessions),
          registered_tools: map_size(state.tools),
          stored_variables: map_size(state.variables)
        }
        {{:ok, info}, state}
      
      _ ->
        {{:error, "Unknown command: #{command}"}, state}
    end
    
    {reply, new_state} = result
    {:reply, reply, new_state}
  end
  
  def handle_cast({:stream, command, args, callback}, state) do
    # Simulate streaming
    Task.start(fn ->
      case command do
        "stream_tokens" ->
          tokens = ["Hello", " from", " the", " bridge", " adapter", "!"]
          for {token, i} <- Enum.with_index(tokens) do
            callback.(%{
              token: token,
              index: i,
              is_final: i == length(tokens) - 1
            })
            Process.sleep(100)
          end
          
        _ ->
          callback.(%{error: "Unknown streaming command: #{command}"})
      end
    end)
    
    {:noreply, state}
  end
  
  # Helper functions
  
  defp generate_beam_run_id do
    "#{:erlang.system_time(:millisecond)}_#{:rand.uniform(9999)}"
  end
  
  defp allocate_port({min, max}) do
    min + :rand.uniform(max - min)
  end
end

# Configure to use our mock bridge adapter
Application.put_env(:snakepit, :adapter_module, MockBridgeAdapter)
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{pool_size: 2})
Application.put_env(:snakepit, :adapter_config, [
  python_path: "/usr/bin/python3",
  grpc_timeout: 5000
])

# Run the example
Snakepit.run_as_script(fn ->
  IO.puts("\n=== Bridge Integration Example ===\n")
  IO.puts("This demonstrates how the three-layer architecture works:")
  IO.puts("- Snakepit (Layer 1): Process management only")
  IO.puts("- Bridge (Layer 2): ML platform functionality")
  IO.puts("- DSPex (Layer 3): Would orchestrate these operations\n")
  
  # Example 1: Session initialization
  session_id = "bridge_session_#{:rand.uniform(1000)}"
  IO.puts("1. Initializing session: #{session_id}")
  {:ok, result} = Snakepit.execute_in_session(
    session_id,
    "initialize_session",
    %{}
  )
  IO.inspect(result, label: "   Session initialized")
  
  # Example 2: Variable management (bridge layer feature)
  IO.puts("\n2. Variable operations:")
  
  # Set variables
  variables = [
    {"temperature", 0.7, "float"},
    {"max_tokens", 100, "integer"},
    {"model", "gpt-4", "string"}
  ]
  
  for {name, value, type} <- variables do
    {:ok, _} = Snakepit.execute_in_session(
      session_id,
      "set_variable",
      %{"name" => name, "value" => value, "type" => type}
    )
    IO.puts("   Set #{name} = #{inspect(value)} (#{type})")
  end
  
  # Get variables
  {:ok, temp_var} = Snakepit.execute_in_session(
    session_id,
    "get_variable",
    %{"name" => "temperature"}
  )
  IO.inspect(temp_var, label: "   Retrieved variable")
  
  # Example 3: Tool registration (bidirectional bridge feature)
  IO.puts("\n3. Tool operations:")
  
  {:ok, _} = Snakepit.execute_in_session(
    session_id,
    "register_tool",
    %{
      "name" => "calculate",
      "spec" => %{
        "description" => "Performs calculations",
        "parameters" => ["expression"]
      }
    }
  )
  IO.puts("   Registered tool: calculate")
  
  {:ok, tool_result} = Snakepit.execute_in_session(
    session_id,
    "execute_tool",
    %{
      "tool" => "calculate",
      "args" => %{"expression" => "2 + 2"}
    }
  )
  IO.inspect(tool_result, label: "   Tool execution result")
  
  # Example 4: ML operations (DSPy integration)
  IO.puts("\n4. ML prediction:")
  {:ok, prediction} = Snakepit.execute_in_session(
    session_id,
    "predict",
    %{
      "signature" => "question -> answer",
      "inputs" => %{"question" => "What is Elixir?"}
    }
  )
  IO.inspect(prediction, label: "   Prediction result")
  
  # Example 5: Streaming (gRPC streaming simulation)
  IO.puts("\n5. Streaming tokens:")
  Snakepit.execute_stream(
    "stream_tokens",
    %{},
    fn chunk ->
      IO.write("   #{chunk.token}")
      if chunk.is_final, do: IO.puts("")
    end,
    session_id: session_id
  )
  Process.sleep(700) # Wait for streaming to complete
  
  # Example 6: Bridge information
  IO.puts("\n6. Bridge worker information:")
  {:ok, info} = Snakepit.execute_in_session(
    session_id,
    "get_bridge_info",
    %{}
  )
  IO.inspect(info, label: "   Worker info", pretty: true)
  
  # Example 7: Demonstrate separation of concerns
  IO.puts("\n7. Architecture separation demonstrated:")
  IO.puts("   - Snakepit handled: process pooling, session routing, lifecycle")
  IO.puts("   - Bridge handled: variables, tools, ML operations, gRPC")
  IO.puts("   - DSPex would handle: high-level orchestration, user API")
  
  IO.puts("\n=== Bridge integration example completed! ===\n")
end)

# Key Concepts Demonstrated:
#
# 1. LAYER SEPARATION: Snakepit knows nothing about ML/gRPC/Python
# 2. BRIDGE FEATURES: Variables, tools, ML ops live in bridge layer
# 3. CLEAN CONTRACT: Adapter behavior is the only coupling point
# 4. SESSION ROUTING: Snakepit handles, bridge leverages
# 5. FUTURE READY: Real bridge would start Python/gRPC processes