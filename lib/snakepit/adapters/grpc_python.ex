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
      # Get the application directory
      app_dir = Application.app_dir(:snakepit)
      Path.join([app_dir, "priv", "python", "grpc_bridge.py"])
    end

    @impl true
    def script_args do
      # Return empty list to let the worker decide the port
      []
    end

    @impl true
    def supported_commands do
      # Basic commands + streaming commands
      [
        "ping",
        "echo",
        "compute",
        "info",
        # Streaming commands
        "ping_stream",
        "batch_inference",
        "process_large_dataset",
        "tail_and_analyze"
      ]
    end

    @impl true
    def validate_command(command, _args) when command in ["ping", "echo", "compute", "info"],
      do: :ok

    def validate_command(command, _args)
        when command in [
               "ping_stream",
               "batch_inference",
               "process_large_dataset",
               "tail_and_analyze"
             ],
        do: :ok

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
    Check if gRPC dependencies are available at runtime.
    """
    def grpc_available? do
      Code.ensure_loaded?(GRPC.Channel) and Code.ensure_loaded?(Protobuf)
    end

    @doc """
    Initialize gRPC connection for the worker.
    Called by GRPCWorker during initialization.
    """
    def init_grpc_connection(port) do
      unless grpc_available?() do
        {:error, :grpc_not_available}
      else
        case Snakepit.GRPC.Client.connect("127.0.0.1", port) do
          {:ok, channel} ->
            {:ok, %{channel: channel, port: port}}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end

    @doc """
    Execute a command via gRPC.
    """
    def grpc_execute(connection, command, args, timeout \\ 30_000) do
      unless grpc_available?() do
        {:error, :grpc_not_available}
      else
        Snakepit.GRPC.Client.execute(connection.channel, command, args, timeout)
      end
    end

    @doc """
    Execute a streaming command via gRPC.
    """
    def grpc_execute_stream(connection, command, args, callback_fn, timeout \\ 300_000) do
      unless grpc_available?() do
        {:error, :grpc_not_available}
      else
        Snakepit.GRPC.Client.execute_stream(
          connection.channel,
          command,
          args,
          callback_fn,
          timeout
        )
      end
    end

    @doc """
    Check if this adapter uses gRPC.
    Returns true only if gRPC dependencies are actually available.
    """
    def uses_grpc?, do: grpc_available?()

    # Compatibility functions for existing adapter interface

    @impl true
    def prepare_args(_command, args), do: args

    @impl true
    def process_response(_command, response), do: {:ok, response}

    @impl true
    # 5 minutes for ML inference
    def command_timeout("batch_inference", _args), do: 300_000
    # 10 minutes for large datasets
    def command_timeout("process_large_dataset", _args), do: 600_000
    # Default 30 seconds
    def command_timeout(_command, _args), do: 30_000
end
