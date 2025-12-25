defmodule Snakepit.GRPC.ClientImpl do
  @moduledoc """
  Real gRPC client implementation using generated stubs.
  """

  require Logger
  alias Snakepit.Bridge
  alias Snakepit.Logger, as: SLog
  alias Snakepit.Telemetry.Correlation

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
    binary_params = Keyword.get(opts, :binary_parameters, %{})

    case prepare_execute_tool_request(session_id, tool_name, parameters, binary_params, opts) do
      {:ok, request, call_opts} ->
        case Bridge.BridgeService.Stub.execute_tool(channel, request, call_opts) do
          {:ok, response, _headers} -> handle_tool_response(response)
          {:ok, response} -> handle_tool_response(response)
          {:error, reason} -> handle_error(reason)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute_streaming_tool(channel, session_id, tool_name, parameters, opts \\ []) do
    binary_params = Keyword.get(opts, :binary_parameters, %{})

    case prepare_execute_stream_request(session_id, tool_name, parameters, binary_params, opts) do
      {:ok, request, call_opts} ->
        Bridge.BridgeService.Stub.execute_streaming_tool(channel, request, call_opts)

      {:error, reason} ->
        {:error, reason}
    end
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
    case Jason.encode(value) do
      {:ok, json_value} ->
        {:ok,
         %Google.Protobuf.Any{
           type_url: "type.googleapis.com/google.protobuf.StringValue",
           value: json_value
         }}

      {:error, %Jason.EncodeError{} = encode_error} ->
        {:error, {:invalid_parameter, :json_encode_failed, Exception.message(encode_error)}}

      {:error, other} ->
        {:error, {:invalid_parameter, :json_encode_failed, inspect(other)}}
    end
  end

  @doc false
  def decode_tool_response(response), do: handle_tool_response(response)

  defp handle_tool_response(%Bridge.ExecuteToolResponse{
         success: true,
         result: any_result,
         binary_result: binary_result
       }) do
    if binary_payload?(binary_result) do
      metadata = decode_any(any_result)
      {:ok, format_binary_result(binary_result, metadata)}
    else
      {:ok, decode_any(any_result)}
    end
  end

  defp handle_tool_response(%Bridge.ExecuteToolResponse{success: false, error_message: error}) do
    {:error, error}
  end

  defp binary_payload?(binary) when is_binary(binary), do: byte_size(binary) > 0
  defp binary_payload?(_), do: false

  defp format_binary_result(binary_result, metadata) do
    case metadata do
      nil -> {:binary, binary_result}
      %{} = map when map_size(map) == 0 -> {:binary, binary_result}
      _ -> {:binary, binary_result, metadata}
    end
  end

  defp decode_any(nil), do: nil

  defp decode_any(%Google.Protobuf.Any{value: value}) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _} -> value
    end
  end

  defp decode_any(%Google.Protobuf.Any{value: value}), do: value

  defp build_execute_tool_request(session_id, tool_name, proto_params, binary_params, metadata) do
    %Bridge.ExecuteToolRequest{
      session_id: session_id,
      tool_name: tool_name,
      parameters: proto_params,
      binary_parameters: binary_params,
      metadata: metadata
    }
  end

  defp encode_parameters(parameters) do
    Enum.reduce_while(parameters, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      case infer_and_encode_any(v) do
        {:ok, proto_any} ->
          {:cont, {:ok, Map.put(acc, to_string(k), proto_any)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
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

  defp encode_binary_parameters(nil), do: {:ok, %{}}

  defp encode_binary_parameters(binary_params) when is_map(binary_params) do
    Enum.reduce_while(binary_params, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      if is_binary(value) do
        {:cont, {:ok, Map.put(acc, to_string(key), value)}}
      else
        {:halt, {:error, {:invalid_parameter, key, :not_binary}}}
      end
    end)
  end

  defp encode_binary_parameters(_), do: {:ok, %{}}

  @doc false
  def prepare_execute_tool_request(session_id, tool_name, parameters, binary_params, opts \\ []) do
    prepare_execute_request(
      session_id,
      tool_name,
      parameters,
      binary_params,
      opts,
      @default_timeout,
      false
    )
  end

  @doc false
  def prepare_execute_stream_request(session_id, tool_name, parameters, binary_params, opts \\ []) do
    prepare_execute_request(
      session_id,
      tool_name,
      parameters,
      binary_params,
      opts,
      300_000,
      true
    )
  end

  defp prepare_execute_request(
         session_id,
         tool_name,
         parameters,
         binary_params,
         opts,
         default_timeout,
         stream?
       ) do
    correlation_id = resolve_correlation_id(parameters, opts)
    parameters = sanitize_parameters(parameters)

    with {:ok, proto_params} <- encode_parameters(parameters),
         {:ok, encoded_binary} <- encode_binary_parameters(binary_params) do
      metadata = build_request_metadata(correlation_id)

      request =
        build_execute_tool_request(session_id, tool_name, proto_params, encoded_binary, metadata)
        |> maybe_put_stream(stream?)

      timeout = opts[:timeout] || default_timeout
      call_opts = [timeout: timeout] |> maybe_put_correlation_metadata(correlation_id)

      {:ok, request, call_opts}
    end
  end

  defp maybe_put_stream(request, true), do: Map.put(request, :stream, true)
  defp maybe_put_stream(request, false), do: request

  defp resolve_correlation_id(parameters, opts) do
    opts_correlation = Keyword.get(opts, :correlation_id)

    (opts_correlation || extract_correlation_id(parameters))
    |> Correlation.ensure()
  end

  defp extract_correlation_id(parameters) when is_map(parameters) do
    Map.get(parameters, :correlation_id) || Map.get(parameters, "correlation_id")
  end

  defp extract_correlation_id(parameters) when is_list(parameters) do
    Enum.find_value(parameters, fn
      {:correlation_id, value} -> value
      {"correlation_id", value} -> value
      _ -> nil
    end)
  end

  defp extract_correlation_id(_), do: nil

  defp build_request_metadata(correlation_id) when is_binary(correlation_id) do
    %{"correlation_id" => correlation_id}
  end

  defp maybe_put_correlation_metadata(call_opts, correlation_id) when is_binary(correlation_id) do
    existing = Keyword.get(call_opts, :metadata, [])

    filtered =
      Enum.reject(existing, fn {key, _} ->
        String.downcase(to_string(key)) == "x-snakepit-correlation-id"
      end)

    Keyword.put(call_opts, :metadata, [{"x-snakepit-correlation-id", correlation_id} | filtered])
  end
end
