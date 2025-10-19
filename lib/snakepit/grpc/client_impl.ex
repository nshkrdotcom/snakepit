defmodule Snakepit.GRPC.ClientImpl do
  @moduledoc """
  Real gRPC client implementation using generated stubs.
  """

  require Logger
  alias Snakepit.Logger, as: SLog
  alias Snakepit.Bridge

  @default_timeout 30_000

  def connect(port) when is_integer(port) do
    connect("localhost:#{port}")
  end

  def connect(address) when is_binary(address) do
    opts = []

    case GRPC.Stub.connect(address, opts) do
      {:ok, channel} ->
        # Verify connection with ping
        case ping(channel, "connection_test") do
          {:ok, _} -> {:ok, channel}
          error -> error
        end

      error ->
        error
    end
  end

  def ping(channel, message, opts \\ []) do
    request = %Bridge.PingRequest{message: message}

    timeout = opts[:timeout] || @default_timeout
    call_opts = [timeout: timeout]

    case Bridge.BridgeService.Stub.ping(channel, request, call_opts) do
      {:ok, response, _headers} ->
        {:ok,
         %{
           message: response.message,
           server_time: response.server_time
         }}

      error ->
        handle_error(error)
    end
  end

  def initialize_session(channel, session_id, config \\ %{}, opts \\ []) do
    metadata = %{
      "elixir_node" => to_string(node()),
      "initialized_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    session_config = %Bridge.SessionConfig{
      enable_caching: Map.get(config, :enable_caching, true),
      cache_ttl_seconds: Map.get(config, :cache_ttl_seconds, 60),
      enable_telemetry: Map.get(config, :enable_telemetry, false)
    }

    request = %Bridge.InitializeSessionRequest{
      session_id: session_id,
      metadata: metadata,
      config: session_config
    }

    timeout = opts[:timeout] || @default_timeout
    call_opts = [timeout: timeout]

    case Bridge.BridgeService.Stub.initialize_session(channel, request, call_opts) do
      {:ok, response, _headers} ->
        {:ok,
         %{
           success: response.success,
           available_tools: response.available_tools,
           error_message: response.error_message
         }}

      error ->
        handle_error(error)
    end
  end

  def cleanup_session(channel, session_id, force \\ false, opts \\ []) do
    request = %Bridge.CleanupSessionRequest{
      session_id: session_id,
      force: force
    }

    timeout = opts[:timeout] || @default_timeout
    call_opts = [timeout: timeout]

    case Bridge.BridgeService.Stub.cleanup_session(channel, request, call_opts) do
      {:ok, response, _headers} ->
        {:ok,
         %{
           success: response.success,
           resources_cleaned: response.resources_cleaned
         }}

      error ->
        handle_error(error)
    end
  end

  def get_session(channel, session_id, opts \\ []) do
    request = %Bridge.GetSessionRequest{
      session_id: session_id
    }

    timeout = opts[:timeout] || @default_timeout
    call_opts = [timeout: timeout]

    case Bridge.BridgeService.Stub.get_session(channel, request, call_opts) do
      {:ok, response, _headers} ->
        if response.session_id do
          {:ok, %{session: decode_session_response(response)}}
        else
          {:error, :not_found}
        end

      {:ok, response} ->
        # Handle 2-tuple response
        if response.session_id do
          {:ok, %{session: decode_session_response(response)}}
        else
          {:error, :not_found}
        end

      error ->
        handle_error(error)
    end
  end

  def heartbeat(channel, session_id, opts \\ []) do
    request = %Bridge.HeartbeatRequest{
      session_id: session_id
    }

    timeout = opts[:timeout] || @default_timeout
    call_opts = [timeout: timeout]

    case Bridge.BridgeService.Stub.heartbeat(channel, request, call_opts) do
      {:ok, response, _headers} ->
        {:ok, %{success: response.session_valid}}

      {:ok, response} ->
        # Handle 2-tuple response
        {:ok, %{success: response.session_valid}}

      error ->
        handle_error(error)
    end
  end

  def execute_tool(channel, session_id, tool_name, parameters, opts \\ []) do
    parameters = sanitize_parameters(parameters)

    # Convert Elixir terms to protobuf Any messages
    proto_params =
      Enum.reduce(parameters, %{}, fn {k, v}, acc ->
        {:ok, proto_any} = infer_and_encode_any(v)
        Map.put(acc, to_string(k), proto_any)
      end)

    request = %Bridge.ExecuteToolRequest{
      session_id: session_id,
      tool_name: tool_name,
      parameters: proto_params
    }

    timeout = opts[:timeout] || @default_timeout
    call_opts = [timeout: timeout]

    case Bridge.BridgeService.Stub.execute_tool(channel, request, call_opts) do
      {:ok, response, _headers} -> handle_tool_response(response)
      {:ok, response} -> handle_tool_response(response)
      {:error, reason} -> handle_error(reason)
    end
  end

  def execute_streaming_tool(channel, session_id, tool_name, parameters, opts \\ []) do
    parameters = sanitize_parameters(parameters)
    proto_params = encode_parameters(parameters)

    request = %Bridge.ExecuteToolRequest{
      session_id: session_id,
      tool_name: tool_name,
      parameters: proto_params,
      stream: true
    }

    timeout = opts[:timeout] || 300_000
    call_opts = [timeout: timeout]

    Bridge.BridgeService.Stub.execute_streaming_tool(channel, request, call_opts)
  end

  # Helper functions

  defp decode_session_response(response) do
    %{
      id: response.session_id,
      # Assume active if we got a response
      active: true,
      created_at: response.created_at,
      # Not provided in response
      last_activity: nil,
      metadata: Map.new(response.metadata || %{})
    }
  end

  defp handle_error({:error, %GRPC.RPCError{} = error}) do
    SLog.error("gRPC error: #{inspect(error)}")

    case error.status do
      3 -> {:error, :invalid_argument}
      5 -> {:error, :not_found}
      13 -> {:error, :internal}
      14 -> {:error, :unavailable}
      _ -> {:error, error}
    end
  end

  defp handle_error(error), do: error

  # Simple encoder for tool parameters - just use JSON encoding for now
  defp infer_and_encode_any(value) do
    json_value = Jason.encode!(value)

    {:ok,
     %Google.Protobuf.Any{
       type_url: "type.googleapis.com/google.protobuf.StringValue",
       value: json_value
     }}
  end

  defp handle_tool_response(%Bridge.ExecuteToolResponse{success: true, result: any_result}) do
    # Simple JSON decoder for tool responses
    case Jason.decode(any_result.value) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:ok, any_result.value}
    end
  end

  defp handle_tool_response(%Bridge.ExecuteToolResponse{success: false, error_message: error}) do
    {:error, error}
  end

  defp encode_parameters(parameters) do
    Enum.reduce(parameters, %{}, fn {k, v}, acc ->
      {:ok, proto_any} = infer_and_encode_any(v)
      Map.put(acc, to_string(k), proto_any)
    end)
  end

  defp sanitize_parameters(parameters) when is_map(parameters) do
    parameters
    |> Map.delete(:correlation_id)
    |> Map.delete("correlation_id")
  end

  defp sanitize_parameters(parameters) when is_list(parameters) do
    parameters
    |> Enum.reject(fn
      {:correlation_id, _} -> true
      {"correlation_id", _} -> true
      _ -> false
    end)
  end

  defp sanitize_parameters(parameters), do: parameters
end
