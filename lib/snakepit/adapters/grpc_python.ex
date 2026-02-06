defmodule Snakepit.Adapters.GRPCPython do
  @moduledoc """
    gRPC-based Python adapter for Snakepit.

    This adapter replaces the stdin/stdout protocol with gRPC for better performance,
    streaming capabilities, and more robust communication.

    ## Configuration

        Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
        Application.put_env(:snakepit, :grpc_listener, %{mode: :internal})

        # External access (explicit opt-in)
        Application.put_env(:snakepit, :grpc_listener, %{
          mode: :external,
          host: "localhost",
          port: 50051
        })

    Worker ports are OS-assigned (ephemeral) and reported back during startup.

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
        handle_chunk(chunk)
      end)
      
      # Stream large dataset processing with progress
      Snakepit.execute_stream("process_large_dataset", %{
        total_rows: 10000,
        chunk_size: 500
      }, fn chunk ->
        handle_progress(chunk)
      end)
  """

  @behaviour Snakepit.Adapter

  alias Snakepit.Bridge.ToolChunk
  alias Snakepit.Defaults
  alias Snakepit.GRPC.Client
  alias Snakepit.Logger, as: SLog
  alias Snakepit.PythonRuntime
  @log_category :grpc

  @impl true
  def executable_path do
    PythonRuntime.executable_path()
  end

  @impl true
  def script_path do
    app_dir = Application.app_dir(:snakepit)
    # Script selection is worker-local in Worker.Configuration based on adapter args.
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

  # gRPC-specific functionality

  @doc """
  Get the gRPC port for this adapter instance.

  ROBUST FIX: Use port 0 to let the OS dynamically assign an available port.
  This completely eliminates:
  - Port collision races
  - TIME_WAIT conflicts
  - Manual port range management
  - Port leak tracking

  Python will bind to an OS-assigned port and report it back via the readiness file
  (`SNAKEPIT_READY_FILE`).
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
  the Python process signals readiness before the OS socket is fully bound
  and accepting connections. This is common in polyglot systems where the
  external process startup timing is non-deterministic.
  """
  def init_grpc_connection(port) do
    if grpc_available?() do
      # Retry up to 5 times with exponential backoff + jitter
      # This handles the startup race condition gracefully
      retry_connect(port, 5, 50, 1)
    else
      {:error, :grpc_not_available}
    end
  end

  # Exponential backoff with jitter to prevent thundering herd during concurrent worker startup.
  # base_delay: initial retry delay (50ms)
  # backoff: multiplier for exponential growth (doubles each retry)
  defp retry_connect(_port, 0, _base_delay, _backoff) do
    # All retries exhausted
    SLog.error(@log_category, "gRPC connection failed after all retries")
    {:error, :connection_failed_after_retries}
  end

  defp retry_connect(port, retries_left, base_delay, backoff) do
    case Client.connect(port) do
      {:ok, channel} ->
        # Connection successful!
        SLog.debug(@log_category, "gRPC connection established to port #{port}")
        {:ok, %{channel: channel, port: port}}

      {:error, reason} when reason in [:connection_refused, :unavailable, :internal, :timeout] ->
        # Socket not ready yet - retry with exponential backoff + jitter
        delay = min(base_delay * backoff, 500)
        # Add ±25% jitter to prevent synchronized retries (thundering herd)
        jitter = :rand.uniform(div(max(delay, 4), 4))
        actual_delay = delay + jitter

        SLog.debug(
          @log_category,
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
          @log_category,
          "gRPC connection to port #{port} failed with unexpected reason: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Execute a command via gRPC.
  """
  def grpc_execute(connection, session_id, command, args, timeout \\ nil, opts \\ [])

  def grpc_execute(connection, session_id, command, args, nil, opts) do
    grpc_execute(connection, session_id, command, args, Defaults.grpc_command_timeout(), opts)
  end

  def grpc_execute(connection, session_id, command, args, timeout, opts) do
    if grpc_available?() do
      call_opts = opts |> List.wrap() |> Keyword.put(:timeout, timeout)

      Client.execute_tool(
        connection.channel,
        session_id,
        command,
        args,
        call_opts
      )
    else
      {:error, :grpc_not_available}
    end
  end

  @doc """
  Execute a streaming command via gRPC with callback.
  """
  def grpc_execute_stream(
        connection,
        session_id,
        command,
        args,
        callback_fn,
        timeout \\ nil,
        opts \\ []
      )

  def grpc_execute_stream(connection, session_id, command, args, callback_fn, nil, opts)
      when is_function(callback_fn, 1) do
    grpc_execute_stream(
      connection,
      session_id,
      command,
      args,
      callback_fn,
      Defaults.grpc_worker_stream_timeout(),
      opts
    )
  end

  def grpc_execute_stream(connection, session_id, command, args, callback_fn, timeout, opts)
      when is_function(callback_fn, 1) do
    if grpc_available?() do
      call_opts = opts |> List.wrap() |> Keyword.put(:timeout, timeout)

      connection.channel
      |> Client.execute_streaming_tool(
        session_id,
        command,
        args,
        call_opts
      )
      |> consume_stream(callback_fn)
    else
      {:error, :grpc_not_available}
    end
  end

  @doc """
  Check if this adapter uses gRPC.
  Returns true only if gRPC dependencies are actually available.
  """
  def uses_grpc?, do: grpc_available?()

  @impl true
  # 5 minutes for ML inference
  def command_timeout("batch_inference", _args), do: Defaults.grpc_batch_inference_timeout()
  # 10 minutes for large datasets
  def command_timeout("process_large_dataset", _args), do: Defaults.grpc_large_dataset_timeout()
  # Default
  def command_timeout(_command, _args), do: Defaults.grpc_command_timeout()

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
