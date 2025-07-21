defmodule Snakepit.GRPC.Client do
  @moduledoc """
  gRPC client wrapper for Snakepit bridge communication.
  """

  require Logger

  alias Snakepit.Grpc.{
    SnakepitBridge.Stub,
    ExecuteRequest,
    ExecuteResponse,
    SessionRequest,
    HealthRequest,
    HealthResponse,
    InfoRequest,
    InfoResponse
  }

  @doc """
  Connect to a gRPC server at the given host and port.
  """
  def connect(host, port) do
    GRPC.Stub.connect("#{host}:#{port}")
  end

  @doc """
  Execute a command via gRPC.
  """
  def execute(channel, command, args, timeout \\ 30_000) do
    request = %ExecuteRequest{
      command: command,
      args: encode_args(args),
      timeout_ms: timeout,
      request_id: generate_request_id()
    }

    case Stub.execute(channel, request, timeout: timeout) do
      {:ok, %ExecuteResponse{success: true} = response} ->
        {:ok, decode_result(response.result)}

      {:ok, %ExecuteResponse{success: false, error: error}} ->
        {:error, error}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Execute a streaming command with a callback function.
  """
  def execute_stream(channel, command, args, callback_fn, timeout \\ 300_000) do
    request_id = generate_request_id()
    Logger.info("[GRPC.Client] execute_stream - command: #{command}, request_id: #{request_id}")

    request = %ExecuteRequest{
      command: command,
      args: encode_args(args),
      timeout_ms: timeout,
      request_id: request_id
    }

    Logger.info("[GRPC.Client] Calling Stub.execute_stream with timeout: #{timeout}")

    # Call the generated stub function and consume the stream with callback
    case Stub.execute_stream(channel, request, timeout: timeout) do
      {:ok, stream} ->
        Logger.info("[GRPC.Client] Got stream from stub, consuming with callback")

        # Consume the gRPC stream properly
        stream
        |> Enum.each(fn response ->
          case response do
            {:ok, stream_response} ->
              # Decode the chunk and call the callback
              decoded_chunk = decode_result(stream_response.chunk)

              callback_fn.(%{
                "data" => decoded_chunk,
                "is_final" => stream_response.is_final,
                "error" => stream_response.error
              })

            {:error, reason} ->
              callback_fn.(%{"error" => inspect(reason), "is_final" => true})
          end
        end)

        :ok

      {:error, reason} ->
        Logger.error("[GRPC.Client] Stub returned error: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("[GRPC.Client] Exception in execute_stream: #{inspect(e)}")
      {:error, e}
  end

  @doc """
  Execute a command within a session.
  """
  def execute_in_session(channel, session_id, command, args, timeout \\ 30_000) do
    request = %SessionRequest{
      session_id: session_id,
      command: command,
      args: encode_args(args),
      timeout_ms: timeout,
      request_id: generate_request_id()
    }

    case Stub.execute_in_session(channel, request, timeout: timeout) do
      {:ok, %ExecuteResponse{success: true} = response} ->
        {:ok, decode_result(response.result)}

      {:ok, %ExecuteResponse{success: false, error: error}} ->
        {:error, error}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Initiate a session-based streaming command and return the stream.
  """
  def execute_in_session_stream(channel, session_id, command, args, timeout \\ 300_000) do
    request = %SessionRequest{
      session_id: session_id,
      command: command,
      args: encode_args(args),
      timeout_ms: timeout,
      request_id: generate_request_id()
    }

    # Return the result from the gRPC library directly
    Stub.execute_in_session_stream(channel, request, timeout: timeout)
  rescue
    e ->
      {:error, e}
  end

  @doc """
  Check health of the gRPC server.
  """
  def health(channel, worker_id \\ "") do
    request = %HealthRequest{worker_id: worker_id}

    case Stub.health(channel, request, timeout: 5_000) do
      {:ok, %HealthResponse{} = response} ->
        {:ok, response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get information about the worker.
  """
  def get_info(channel, include_capabilities \\ true, include_stats \\ true) do
    request = %InfoRequest{
      include_capabilities: include_capabilities,
      include_stats: include_stats
    }

    case Stub.get_info(channel, request, timeout: 10_000) do
      {:ok, %InfoResponse{} = response} ->
        {:ok, response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private helper functions

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
      # Keep as binary if not JSON
      _ -> v
    end
  end

  defp generate_request_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
