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
  alias Snakepit.Logger, as: SLog
  alias Snakepit.Bridge.ToolChunk

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

    # Check if we should use threaded server based on adapter args
    # Check both old pool_config format and new pools format
    pool_config = Application.get_env(:snakepit, :pool_config, %{})
    pools_config = Application.get_env(:snakepit, :pools, [])

    # Get adapter args from either source
    adapter_args = Map.get(pool_config, :adapter_args, [])

    # Also check if any pool is configured with --max-workers in pools config
    has_max_workers =
      Enum.any?(adapter_args, fn arg ->
        is_binary(arg) and String.contains?(arg, "--max-workers")
      end) or
        Enum.any?(pools_config, fn pool_cfg ->
          pool_adapter_args = Map.get(pool_cfg, :adapter_args, [])

          Enum.any?(pool_adapter_args, fn arg ->
            is_binary(arg) and String.contains?(arg, "--max-workers")
          end)
        end)

    # Use threaded server if --max-workers is specified (indicates threaded mode)
    script_name =
      if has_max_workers do
        "grpc_server_threaded.py"
      else
        "grpc_server.py"
      end

    Path.join([app_dir, "priv", "python", script_name])
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

  ROBUST FIX: Use port 0 to let the OS dynamically assign an available port.
  This completely eliminates:
  - Port collision races
  - TIME_WAIT conflicts
  - Manual port range management
  - Port leak tracking

  Python will bind to an OS-assigned port and report it back via GRPC_READY.
  """
  def get_port do
    # Port 0 = "OS, please assign me any available port"
    0
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

  CRITICAL FIX: This includes retry logic to handle the race condition where
  the Python process signals GRPC_READY before the OS socket is fully bound
  and accepting connections. This is common in polyglot systems where the
  external process startup timing is non-deterministic.
  """
  def init_grpc_connection(port) do
    unless grpc_available?() do
      {:error, :grpc_not_available}
    else
      # Retry up to 5 times with exponential backoff + jitter
      # This handles the startup race condition gracefully
      retry_connect(port, 5, 50, 1)
    end
  end

  # Exponential backoff with jitter to prevent thundering herd during concurrent worker startup.
  # base_delay: initial retry delay (50ms)
  # backoff: multiplier for exponential growth (doubles each retry)
  defp retry_connect(_port, 0, _base_delay, _backoff) do
    # All retries exhausted
    SLog.error("gRPC connection failed after all retries")
    {:error, :connection_failed_after_retries}
  end

  defp retry_connect(port, retries_left, base_delay, backoff) do
    case Snakepit.GRPC.Client.connect(port) do
      {:ok, channel} ->
        # Connection successful!
        SLog.debug("gRPC connection established to port #{port}")
        {:ok, %{channel: channel, port: port}}

      {:error, reason} when reason in [:connection_refused, :unavailable, :internal] ->
        # Socket not ready yet - retry with exponential backoff + jitter
        delay = min(base_delay * backoff, 500)
        # Add ±25% jitter to prevent synchronized retries (thundering herd)
        jitter = :rand.uniform(div(max(delay, 4), 4))
        actual_delay = delay + jitter

        SLog.debug(
          "gRPC connection to port #{port} #{reason}. " <>
            "Retrying in #{actual_delay}ms... (#{retries_left - 1} retries left)"
        )

        # OTP-idiomatic non-blocking wait
        receive do
        after
          actual_delay -> :ok
        end

        retry_connect(port, retries_left - 1, base_delay, backoff * 2)

      {:error, reason} ->
        # For any other error, fail immediately (no retry)
        SLog.error(
          "gRPC connection to port #{port} failed with unexpected reason: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Execute a command via gRPC.
  """
  def grpc_execute(connection, session_id, command, args, timeout \\ 30_000) do
    unless grpc_available?() do
      {:error, :grpc_not_available}
    else
      Snakepit.GRPC.Client.execute_tool(
        connection.channel,
        session_id,
        command,
        args,
        timeout: timeout
      )
    end
  end

  @doc """
  Execute a streaming command via gRPC with callback.
  """
  def grpc_execute_stream(connection, session_id, command, args, callback_fn, timeout \\ 300_000)
      when is_function(callback_fn, 1) do
    unless grpc_available?() do
      {:error, :grpc_not_available}
    else
      connection.channel
      |> Snakepit.GRPC.Client.execute_streaming_tool(
        session_id,
        command,
        args,
        timeout: timeout
      )
      |> consume_stream(callback_fn)
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

  defp consume_stream({:ok, stream}, callback_fn) do
    Enum.reduce_while(stream, :ok, fn message, _acc ->
      process_stream_message(message, callback_fn)
    end)
  end

  defp consume_stream({:error, reason}, _callback_fn), do: {:error, reason}

  defp process_stream_message({:ok, %ToolChunk{} = chunk}, callback_fn) do
    deliver_chunk(chunk, callback_fn)
  end

  defp process_stream_message(%ToolChunk{} = chunk, callback_fn) do
    deliver_chunk(chunk, callback_fn)
  end

  defp process_stream_message({:error, reason}, _callback_fn), do: {:halt, {:error, reason}}

  defp process_stream_message(other, _callback_fn),
    do: {:halt, {:error, {:unexpected_stream_item, other}}}

  defp deliver_chunk(%ToolChunk{} = chunk, callback_fn) do
    payload = build_payload(chunk)

    try do
      case callback_fn.(payload) do
        :halt -> {:halt, :ok}
        {:halt, reason} -> {:halt, {:error, reason}}
        _ -> {:cont, :ok}
      end
    rescue
      exception ->
        {:halt, {:error, {:callback_exception, exception, __STACKTRACE__}}}
    end
  end

  defp build_payload(%ToolChunk{} = chunk) do
    base =
      case decode_chunk_data(chunk.data) do
        :empty -> %{}
        {:ok, %{} = map} -> map
        {:ok, value} -> %{"data" => value}
        {:error, raw} -> %{"raw_data_base64" => raw}
      end

    base
    |> Map.put("is_final", chunk.is_final)
    |> maybe_with_metadata(chunk.metadata)
  end

  defp decode_chunk_data(data) when is_binary(data) do
    if data == "" do
      :empty
    else
      case Jason.decode(data) do
        {:ok, decoded} -> {:ok, decoded}
        {:error, _} -> {:error, Base.encode64(data)}
      end
    end
  end

  defp decode_chunk_data(_), do: :empty

  defp maybe_with_metadata(payload, metadata) when metadata in [%{}, nil], do: payload

  defp maybe_with_metadata(payload, metadata) do
    metadata
    |> Map.new()
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
    |> case do
      %{} = cleaned when map_size(cleaned) > 0 -> Map.put(payload, "_metadata", cleaned)
      _ -> payload
    end
  end
end
