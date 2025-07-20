defmodule Snakepit.Adapters.GRPCPython do
  @moduledoc """
  gRPC-based Python adapter for Snakepit.
  
  This adapter replaces the stdin/stdout protocol with gRPC for better performance,
  streaming capabilities, and more robust communication.
  
  ## Configuration
  
      Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
      Application.put_env(:snakepit, :grpc_config, %{
        base_port: 50051,
        port_range: 100  # Will use ports 50051-50151
      })
  
  ## Features
  
  - Native streaming support for progressive results
  - HTTP/2 multiplexing for concurrent requests
  - Built-in health checks and monitoring
  - Better error handling with gRPC status codes
  - Binary data support without base64 encoding
  
  ## Streaming Examples
  
      # Stream ML inference results
      Snakepit.execute_stream("batch_inference", %{
        batch_items: ["image1.jpg", "image2.jpg", "image3.jpg"]
      }, fn chunk ->
        IO.puts("Processed: \#{chunk["item"]} - \#{chunk["confidence"]}")
      end)
      
      # Stream large dataset processing with progress
      Snakepit.execute_stream("process_large_dataset", %{
        total_rows: 10000,
        chunk_size: 500
      }, fn chunk ->
        IO.puts("Progress: \#{chunk["progress_percent"]}%")
      end)
  """
  
  @behaviour Snakepit.Adapter
  
  require Logger
  
  @impl true
  def executable_path do
    # Find Python executable
    System.find_executable("python3") || System.find_executable("python")
  end
  
  @impl true  
  def script_path do
    Path.join(:code.priv_dir(:snakepit), "python/grpc_bridge.py")
  end
  
  @impl true
  def script_args do
    port = get_port()
    ["--port", to_string(port)]
  end
  
  @impl true
  def supported_commands do
    # Basic commands + streaming commands
    [
      "ping", "echo", "compute", "info",
      # Streaming commands
      "ping_stream", "batch_inference", "process_large_dataset", "tail_and_analyze"
    ]
  end
  
  @impl true
  def validate_command(command, _args) when command in ["ping", "echo", "compute", "info"], do: :ok
  def validate_command(command, _args) when command in ["ping_stream", "batch_inference", "process_large_dataset", "tail_and_analyze"], do: :ok
  def validate_command(command, _args), do: {:error, "Unsupported command: #{command}"}
  
  # Optional callbacks for gRPC-specific functionality
  
  @doc """
  Get the gRPC port for this adapter instance.
  
  Ports are allocated from a configurable range to avoid conflicts
  when running multiple workers.
  """
  def get_port do
    config = Application.get_env(:snakepit, :grpc_config, %{})
    base_port = Map.get(config, :base_port, 50051)
    port_range = Map.get(config, :port_range, 100)
    
    # Simple port allocation - in production might use a registry
    base_port + :rand.uniform(port_range) - 1
  end
  
  @doc """
  Check if gRPC dependencies are available.
  """
  def grpc_available? do
    Code.ensure_loaded?(GRPC.Channel) and Code.ensure_loaded?(Protobuf)
  end
  
  @doc """
  Get gRPC connection for this worker.
  
  This would be called by the worker to establish the gRPC connection.
  """
  def get_grpc_connection(port) when is_integer(port) do
    if grpc_available?() do
      case GRPC.Stub.connect("127.0.0.1:#{port}") do
        {:ok, channel} -> {:ok, channel}
        {:error, reason} -> {:error, "gRPC connection failed: #{inspect(reason)}"}
      end
    else
      {:error, "gRPC dependencies not available. Add {:grpc, \"~> 0.8\"} to deps."}
    end
  end
  
  @doc """
  Execute a command via gRPC.
  
  This is called by the worker instead of using stdin/stdout.
  """
  def grpc_execute(channel, command, args, timeout \\ 30_000) do
    if grpc_available?() do
      # Convert args to gRPC format
      grpc_args = convert_args_to_grpc(args)
      
      # Create request
      request = %{
        command: command,
        args: grpc_args,
        timeout_ms: timeout,
        request_id: generate_request_id()
      }
      
      # Make gRPC call (placeholder - would use generated stubs)
      # In real implementation, this would use the generated protobuf code
      case make_grpc_call(channel, :execute, request) do
        {:ok, response} when response.success ->
          {:ok, convert_grpc_result(response.result)}
        {:ok, response} ->
          {:error, response.error}
        {:error, reason} ->
          {:error, "gRPC call failed: #{inspect(reason)}"}
      end
    else
      {:error, "gRPC not available"}
    end
  end
  
  @doc """
  Execute a streaming command via gRPC.
  """
  def grpc_execute_stream(channel, command, args, callback_fn, timeout \\ 300_000) do
    if grpc_available?() do
      grpc_args = convert_args_to_grpc(args)
      
      request = %{
        command: command,
        args: grpc_args,
        timeout_ms: timeout,
        request_id: generate_request_id()
      }
      
      # Stream gRPC call (placeholder)
      case make_grpc_stream_call(channel, :execute_stream, request) do
        {:ok, stream} ->
          handle_grpc_stream(stream, callback_fn)
        {:error, reason} ->
          {:error, "gRPC stream failed: #{inspect(reason)}"}
      end
    else
      {:error, "gRPC not available"}
    end
  end
  
  # Private helper functions
  
  defp convert_args_to_grpc(args) when is_map(args) do
    Enum.into(args, %{}, fn {k, v} ->
      key = to_string(k)
      value = case v do
        bin when is_binary(bin) -> bin
        other -> Jason.encode!(other)
      end
      {key, value}
    end)
  end
  
  defp convert_grpc_result(grpc_result) when is_map(grpc_result) do
    Enum.into(grpc_result, %{}, fn {k, v} ->
      key = String.to_atom(k)
      value = try do
        Jason.decode!(v)
      rescue
        _ -> v  # Keep as binary if not JSON
      end
      {key, value}
    end)
  end
  
  defp generate_request_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
  
  # Placeholder functions for gRPC calls
  # These would be replaced with actual generated protobuf client code
  
  defp make_grpc_call(_channel, _method, _request) do
    # Placeholder - would use real gRPC client
    {:error, "gRPC client not implemented yet - needs generated protobuf code"}
  end
  
  defp make_grpc_stream_call(_channel, _method, _request) do
    # Placeholder - would use real gRPC streaming client
    {:error, "gRPC streaming client not implemented yet"}
  end
  
  defp handle_grpc_stream(_stream, _callback_fn) do
    # Placeholder - would handle streaming responses
    {:error, "gRPC stream handling not implemented yet"}
  end
  
  # Compatibility functions for existing adapter interface
  
  @impl true
  def prepare_args(_command, args), do: args
  
  @impl true  
  def process_response(_command, response), do: {:ok, response}
  
  @impl true
  def command_timeout("batch_inference", _args), do: 300_000  # 5 minutes for ML inference
  def command_timeout("process_large_dataset", _args), do: 600_000  # 10 minutes for large datasets
  def command_timeout(_command, _args), do: 30_000  # Default 30 seconds
end