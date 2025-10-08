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
    # Priority order for finding Python:
    # 1. Explicit configuration (highest priority)
    # 2. Environment variable
    # 3. Auto-detect virtual environment (dev convenience)
    # 4. System Python (fallback for production)
    Application.get_env(:snakepit, :python_executable) ||
      System.get_env("SNAKEPIT_PYTHON") ||
      find_venv_python() ||
      System.find_executable("python3") || System.find_executable("python")
  end

  defp find_venv_python do
    candidates = [
      # Project root venv
      ".venv/bin/python3",
      # Parent directory venv (for examples/ subdirectory)
      "../.venv/bin/python3",
      # VIRTUAL_ENV variable (if venv activated)
      System.get_env("VIRTUAL_ENV") &&
        Path.join([System.get_env("VIRTUAL_ENV"), "bin", "python3"])
    ]

    Enum.find_value(candidates, fn path ->
      path && File.exists?(Path.expand(path)) && Path.expand(path)
    end)
  end

  @impl true
  def script_path do
    # Get the application directory
    app_dir = Application.app_dir(:snakepit)
    Path.join([app_dir, "priv", "python", "grpc_server.py"])
  end

  @impl true
  def script_args do
    # Check if custom adapter args are provided in pool config
    pool_config = Application.get_env(:snakepit, :pool_config, %{})
    adapter_args = Map.get(pool_config, :adapter_args, nil)

    if adapter_args do
      # Use custom adapter args if provided
      adapter_args
    else
      # Default to ShowcaseAdapter - fully functional reference implementation
      # For custom adapters, set pool_config.adapter_args or use TemplateAdapter as starting point
      ["--adapter", "snakepit_bridge.adapters.showcase.ShowcaseAdapter"]
    end
  end

  @impl true
  def supported_commands do
    # Check if we're using DSPy adapter
    pool_config = Application.get_env(:snakepit, :pool_config, %{})
    adapter_args = Map.get(pool_config, :adapter_args, [])

    base_commands = [
      "ping",
      "echo",
      "compute",
      "info",
      # Enhanced Python API
      "call",
      "store",
      "retrieve",
      "list_stored",
      "delete_stored"
    ]

    streaming_commands = [
      "ping_stream",
      "batch_inference",
      "process_large_dataset",
      "tail_and_analyze"
    ]

    dspy_commands = [
      "configure_lm",
      "create_program",
      "create_gemini_program",
      "execute_program",
      "execute_gemini_program",
      "list_programs",
      "delete_program",
      "get_stats",
      "cleanup",
      "reset_state",
      "get_program_info",
      "cleanup_session",
      "shutdown"
    ]

    # Include DSPy commands if using DSPy adapter
    if Enum.any?(adapter_args, &String.contains?(&1, "dspy")) do
      base_commands ++ streaming_commands ++ dspy_commands
    else
      base_commands ++ streaming_commands
    end
  end

  @impl true
  def validate_command(command, _args) do
    supported = supported_commands()

    if command in supported do
      :ok
    else
      {:error, "Unsupported command: #{command}"}
    end
  end

  # Optional callbacks for gRPC-specific functionality

  @doc """
  Get the gRPC port for this adapter instance.

  Ports are allocated from a configurable range to avoid conflicts
  when running multiple workers.
  """
  def get_port do
    config = Application.get_env(:snakepit, :grpc_config, %{})
    # Start at 50052 to avoid Elixir server
    base_port = Map.get(config, :base_port, 50052)
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
      case Snakepit.GRPC.Client.connect(port) do
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
      Snakepit.GRPC.Client.execute_tool(
        connection.channel,
        "default_session",
        command,
        args,
        timeout: timeout
      )
    end
  end

  @doc """
  Execute a streaming command via gRPC with callback.
  """
  def grpc_execute_stream(connection, command, args, callback_fn, timeout \\ 300_000) do
    Logger.info(
      "[GRPCPython] grpc_execute_stream - command: #{command}, args: #{inspect(args)}, timeout: #{timeout}"
    )

    unless grpc_available?() do
      Logger.error("[GRPCPython] gRPC not available")
      {:error, :grpc_not_available}
    else
      # Use the streaming endpoint
      Logger.info("[GRPCPython] Using streaming endpoint")
      Logger.info("[GRPCPython] Channel info: #{inspect(connection.channel)}")

      result =
        Snakepit.GRPC.Client.execute_streaming_tool(
          connection.channel,
          "default_session",
          command,
          args,
          timeout: timeout
        )

      Logger.info("[GRPCPython] execute_streaming_tool returned: #{inspect(result)}")

      case result do
        {:ok, stream} ->
          Logger.info("[GRPCPython] Starting to consume stream...")
          # Consume the stream directly without Task.async to avoid deadlock
          try do
            Logger.info("[GRPCPython] Starting Enum.each on stream")

            Enum.each(stream, fn chunk ->
              case chunk do
                {:ok, %Snakepit.Bridge.ToolChunk{data: data_bytes, is_final: false}}
                when is_binary(data_bytes) ->
                  # Decode the JSON payload from the chunk
                  decoded_chunk = Jason.decode!(data_bytes)
                  Logger.info("[GRPCPython] Decoded chunk: #{inspect(decoded_chunk)}")
                  callback_fn.(decoded_chunk)

                {:ok, %Snakepit.Bridge.ToolChunk{is_final: true}} ->
                  # Final empty chunk, ignore
                  Logger.info("[GRPCPython] Received final chunk")

                {:error, reason} ->
                  Logger.error("[GRPCPython] Stream error: #{inspect(reason)}")
                  callback_fn.({:error, reason})

                other ->
                  Logger.warning("[GRPCPython] Unexpected chunk format: #{inspect(other)}")
              end
            end)

            Logger.info("[GRPCPython] Stream consumption complete")
            :ok
          rescue
            e ->
              Logger.error("[GRPCPython] Error consuming stream: #{inspect(e)}")
              {:error, e}
          end

        {:error, reason} ->
          Logger.error("[GRPCPython] Failed to initiate stream: #{inspect(reason)}")
          {:error, reason}
      end
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
