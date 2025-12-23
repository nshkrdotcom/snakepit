defmodule Snakepit.GRPC.BridgeServer do
  @moduledoc """
  gRPC server implementation for the Snakepit Bridge service.

  Handles tool execution and session management through the unified bridge protocol.
  """

  use GRPC.Server, service: Snakepit.Bridge.BridgeService.Service

  alias Snakepit.Bridge.SessionStore
  alias Snakepit.Bridge.ToolRegistry
  alias Snakepit.GRPCWorker
  alias Snakepit.GRPC.Client, as: GRPCClient
  alias Snakepit.Pool.Registry, as: PoolRegistry
  alias Snakepit.Telemetry.Correlation

  alias Snakepit.Bridge.{
    PingRequest,
    PingResponse,
    InitializeSessionResponse,
    CleanupSessionRequest,
    CleanupSessionResponse,
    GetSessionRequest,
    GetSessionResponse,
    HeartbeatRequest,
    HeartbeatResponse,
    ExecuteToolRequest,
    ExecuteToolResponse,
    RegisterToolsRequest,
    RegisterToolsResponse,
    GetExposedElixirToolsRequest,
    GetExposedElixirToolsResponse,
    ExecuteElixirToolRequest,
    ExecuteElixirToolResponse,
    ToolSpec,
    ParameterSpec
  }

  alias Google.Protobuf.{Any, Timestamp}

  require Logger
  alias Snakepit.Logger, as: SLog

  # Health & Session Management

  def ping(%PingRequest{message: message}, _stream) do
    SLog.debug("Ping received: #{message}")

    %PingResponse{
      message: "pong: #{message}",
      server_time: %Timestamp{seconds: System.system_time(:second), nanos: 0}
    }
  end

  def initialize_session(request, _stream) do
    SLog.info("Initializing session: #{request.session_id}")

    case SessionStore.create_session(request.session_id, metadata: request.metadata) do
      {:ok, _session} ->
        # Success - session was created or already existed (both are fine)
        %InitializeSessionResponse{
          success: true,
          error_message: nil,
          available_tools: %{}
        }

      {:error, reason} ->
        # Only raise on actual errors (not :already_exists, which is now handled)
        raise GRPC.RPCError,
          status: :internal,
          message: format_error(reason)
    end
  end

  def cleanup_session(%CleanupSessionRequest{session_id: session_id, force: _force}, _stream) do
    SLog.info("Cleaning up session: #{session_id}")

    # TODO: Implement force flag when supported by SessionStore
    # SessionStore.delete_session always returns :ok
    SessionStore.delete_session(session_id)

    %CleanupSessionResponse{
      success: true,
      resources_cleaned: 1
    }
  end

  def get_session(%GetSessionRequest{session_id: session_id}, _stream) do
    SLog.debug("GetSession: #{session_id}")

    case SessionStore.get_session(session_id) do
      {:ok, session} ->
        tools = Map.get(session, :tools, %{})
        metadata = Map.get(session, :metadata, %{})

        tool_count = map_size(tools)

        %GetSessionResponse{
          session_id: session_id,
          metadata: metadata,
          created_at: %Timestamp{seconds: session.created_at, nanos: 0},
          tool_count: tool_count
        }

      {:error, :not_found} ->
        raise GRPC.RPCError,
          status: :not_found,
          message: "Session not found: #{session_id}"
    end
  end

  def heartbeat(%HeartbeatRequest{session_id: session_id, client_time: _client_time}, _stream) do
    SLog.debug("Heartbeat: #{session_id}")

    # Check if session exists and update last_accessed
    session_valid =
      case SessionStore.get_session(session_id) do
        {:ok, _session} ->
          # Getting the session automatically updates last_accessed
          true

        {:error, :not_found} ->
          false
      end

    %HeartbeatResponse{
      server_time: %Timestamp{seconds: System.system_time(:second), nanos: 0},
      session_valid: session_valid
    }
  end

  # Tool Execution

  def execute_tool(%ExecuteToolRequest{} = request, stream) do
    SLog.info("ExecuteTool: #{request.tool_name} for session #{request.session_id}")

    start_time = System.monotonic_time(:millisecond)
    correlation_id = resolve_request_correlation_id(request, stream)
    request = ensure_request_correlation(request, correlation_id)

    with {:ok, _session} <- SessionStore.get_session(request.session_id),
         {:ok, tool} <- ToolRegistry.get_tool(request.session_id, request.tool_name),
         {:ok, result} <-
           execute_tool_handler(tool, request, request.session_id, correlation_id) do
      execution_time = System.monotonic_time(:millisecond) - start_time
      {encoded_result, binary_result} = encode_tool_result(result)

      %ExecuteToolResponse{
        success: true,
        result: encoded_result,
        binary_result: binary_result || <<>>,
        error_message: nil,
        metadata: %{
          "execution_time" => to_string(execution_time),
          "tool_type" => to_string(tool.type)
        },
        execution_time_ms: execution_time
      }
    else
      {:error, reason} ->
        %ExecuteToolResponse{
          success: false,
          result: nil,
          error_message: format_error(reason),
          metadata: %{},
          execution_time_ms: System.monotonic_time(:millisecond) - start_time
        }
    end
  end

  defp execute_tool_handler(%{type: :local} = tool, request, session_id, _correlation_id) do
    # Execute local Elixir tool
    case decode_tool_parameters(request.parameters, request.binary_parameters) do
      {:ok, params} ->
        ToolRegistry.execute_local_tool(session_id, tool.name, params)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_tool_handler(%{type: :remote} = tool, request, session_id, correlation_id) do
    # Forward to Python worker
    SLog.debug("Executing remote tool #{tool.name} on worker #{tool.worker_id}")

    with {:ok, params} <- decode_tool_parameters(request.parameters, request.binary_parameters),
         {:ok, channel, cleanup} <- ensure_worker_channel(tool.worker_id) do
      result =
        try do
          forward_tool_to_worker(channel, request, session_id, params, correlation_id)
        after
          cleanup.()
        end

      case result do
        {:ok, response} ->
          {:ok, response}

        {:error, reason} ->
          SLog.error("Failed to execute remote tool #{tool.name}: #{inspect(reason)}")
          {:error, {:remote_execution_failed, reason}}
      end
    else
      {:error, {:invalid_parameter, _, _}} = error ->
        error

      {:error, reason} ->
        SLog.error("Failed to execute remote tool #{tool.name}: #{inspect(reason)}")
        {:error, {:remote_execution_failed, reason}}
    end
  end

  defp decode_tool_parameters(params, binary_params)
       when is_map(params) and (is_map(binary_params) or is_nil(binary_params)) do
    decoded =
      Enum.reduce_while(params, {:ok, %{}}, fn {key, any_value}, {:ok, acc} ->
        case decode_any_value(any_value) do
          {:ok, decoded} ->
            {:cont, {:ok, Map.put(acc, key, decoded)}}

          {:error, reason} ->
            {:halt, {:error, {:invalid_parameter, key, reason}}}
        end
      end)

    case decoded do
      {:ok, acc} ->
        merge_binary_parameters(acc, binary_params || %{})

      other ->
        other
    end
  end

  defp decode_tool_parameters(_, _), do: {:ok, %{}}

  defp decode_any_value(%Any{
         type_url: "type.googleapis.com/google.protobuf.StringValue",
         value: value
       }) do
    decode_json(value)
  end

  defp decode_any_value(%Any{type_url: type_url, value: value}) do
    case decode_json(value) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, message} ->
        {:error, {:invalid_json, message, type_url}}
    end
  end

  defp decode_any_value(value) when is_map(value) or is_list(value) do
    {:ok, value}
  end

  defp merge_binary_parameters(decoded, binary_params) when map_size(binary_params) == 0,
    do: {:ok, decoded}

  defp merge_binary_parameters(decoded, binary_params) when is_map(binary_params) do
    Enum.reduce_while(binary_params, {:ok, decoded}, fn {key, value}, {:ok, acc} ->
      cond do
        is_binary(value) ->
          {:cont, {:ok, Map.put(acc, normalize_param_key(key), {:binary, value})}}

        true ->
          {:halt, {:error, {:invalid_parameter, normalize_param_key(key), :not_binary}}}
      end
    end)
  end

  defp merge_binary_parameters(decoded, _binary_params), do: {:ok, decoded}

  defp normalize_param_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_param_key(key) when is_binary(key), do: key
  defp normalize_param_key(key), do: to_string(key)

  defp decode_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, %Jason.DecodeError{} = decode_error} ->
        {:error, Exception.message(decode_error)}
    end
  end

  defp decode_json(_), do: {:error, "expected JSON encoded string"}

  # Helper functions for remote tool execution

  defp get_worker_port(worker_id) do
    case PoolRegistry.get_worker_pid(worker_id) do
      {:ok, pid} when is_pid(pid) ->
        # Try to get port from worker state - this is a simplified approach
        try do
          case GenServer.call(pid, :get_port, 1000) do
            {:ok, port} -> {:ok, port}
            _ -> {:error, "Could not get port from worker"}
          end
        catch
          _exit, _reason -> {:error, "Worker not responding"}
        end

      {:error, _reason} ->
        {:error, "Worker not found: #{worker_id}"}
    end
  end

  defp create_worker_channel(port) do
    try do
      GRPC.Stub.connect("localhost:#{port}")
    rescue
      error -> {:error, "Failed to connect to worker: #{inspect(error)}"}
    end
  end

  defp forward_tool_to_worker(channel, request, session_id, decoded_params, correlation_id) do
    worker_metadata = ensure_metadata_correlation(request.metadata, correlation_id)

    # Create the request to forward to the worker
    worker_request = %ExecuteToolRequest{
      session_id: session_id,
      tool_name: request.tool_name,
      parameters: request.parameters,
      metadata: worker_metadata,
      binary_parameters: request.binary_parameters
    }

    binary_params = worker_request.binary_parameters || %{}

    opts =
      worker_request.metadata
      |> tool_call_options()
      |> Keyword.put(:binary_parameters, binary_params)
      |> Keyword.put(:correlation_id, correlation_id)

    case GRPCClient.execute_tool(
           channel,
           worker_request.session_id,
           worker_request.tool_name,
           decoded_params,
           opts
         ) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp tool_call_options(metadata) when is_map(metadata) do
    metadata
    |> Map.get("timeout_ms") ||
      Map.get(metadata, :timeout_ms)
      |> parse_timeout_ms()
      |> case do
        {:ok, timeout} -> [timeout: timeout]
        :error -> []
      end
  end

  defp resolve_request_correlation_id(request, stream) do
    request
    |> correlation_id_from_metadata()
    |> case do
      nil -> correlation_id_from_headers(stream)
      value -> value
    end
    |> Correlation.ensure()
  end

  defp correlation_id_from_metadata(%{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "correlation_id") || Map.get(metadata, :correlation_id)
  end

  defp correlation_id_from_metadata(_), do: nil

  defp correlation_id_from_headers(nil), do: nil

  defp correlation_id_from_headers(stream) do
    stream
    |> GRPC.Stream.get_headers()
    |> Map.get("x-snakepit-correlation-id")
  end

  defp ensure_request_correlation(%ExecuteToolRequest{} = request, correlation_id) do
    metadata = ensure_metadata_correlation(request.metadata, correlation_id)
    %{request | metadata: metadata}
  end

  defp ensure_metadata_correlation(nil, correlation_id) do
    %{"correlation_id" => correlation_id}
  end

  defp ensure_metadata_correlation(metadata, correlation_id) when is_map(metadata) do
    Map.put(metadata, "correlation_id", correlation_id)
  end

  defp parse_timeout_ms(nil), do: :error

  defp parse_timeout_ms(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_timeout_ms(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_timeout_ms(_), do: :error

  defp ensure_worker_channel(worker_id) do
    case get_existing_worker_channel(worker_id) do
      {:ok, channel} ->
        {:ok, channel, fn -> :ok end}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, _reason} ->
        with {:ok, port} <- get_worker_port(worker_id),
             {:ok, channel} <- create_worker_channel(port) do
          {:ok, channel, fn -> disconnect_channel(channel) end}
        end
    end
  end

  defp get_existing_worker_channel(worker_id) do
    case PoolRegistry.fetch_worker(worker_id) do
      {:ok, pid, metadata} when is_pid(pid) ->
        case Map.get(metadata, :worker_module, GRPCWorker) do
          module when module == GRPCWorker ->
            case GRPCWorker.get_channel(pid) do
              {:ok, channel} -> {:ok, channel}
              {:error, reason} -> {:error, reason}
            end

          _ ->
            {:error, :unsupported_worker_module}
        end

      {:error, _} ->
        {:error, "Worker not found: #{worker_id}"}
    end
  rescue
    _ -> {:error, :channel_unavailable}
  end

  defp disconnect_channel(channel) do
    try do
      _ = GRPC.Stub.disconnect(channel)
      :ok
    rescue
      _ -> :ok
    end
  end

  def execute_streaming_tool(%ExecuteToolRequest{} = request, _stream) do
    hint =
      "Streaming execution is not enabled for tool #{request.tool_name}. " <>
        "Enable streaming support on the adapter (set supports_streaming: true) or use execute_tool instead. " <>
        "See docs/20251026/SNAKEPIT_STREAMING_PROMPT.md for enablement steps."

    SLog.warning(
      "Streaming request received for #{request.tool_name} but streaming support is disabled. Returning UNIMPLEMENTED."
    )

    raise GRPC.RPCError,
      status: :unimplemented,
      message: hint
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: to_string(reason)
  defp format_error({:error, reason}), do: format_error(reason)
  defp format_error({:unknown_type, type}), do: "Unknown type: #{inspect(type)}"
  defp format_error({:invalid_constraints, reason}), do: "Invalid constraints: #{reason}"

  defp format_error({:invalid_parameter, key, {:invalid_json, message}}) do
    "Invalid parameter #{key}: #{message}"
  end

  defp format_error({:invalid_parameter, key, {:invalid_json, message, type_url}}) do
    "Invalid parameter #{key} (#{type_url}): #{message}"
  end

  defp format_error({:invalid_parameter, key, reason}) do
    "Invalid parameter #{key}: #{inspect(reason)}"
  end

  defp format_error({:remote_execution_failed, reason}) when is_binary(reason) do
    "Remote tool execution failed: #{reason}"
  end

  defp format_error({:remote_execution_failed, reason}) do
    "Remote tool execution failed: #{inspect(reason)}"
  end

  defp format_error({:validation_failed, details}) when is_map(details) do
    "Validation failed: #{inspect(details)}"
  end

  defp format_error(reason), do: inspect(reason)

  # Tool Registration & Discovery

  def register_tools(%RegisterToolsRequest{} = request, _stream) do
    SLog.info("RegisterTools for session #{request.session_id}, worker: #{request.worker_id}")

    with {:ok, _session} <- SessionStore.get_session(request.session_id) do
      # Convert proto ToolRegistration to internal format
      tool_specs =
        Enum.map(request.tools, fn tool_reg ->
          %{
            name: tool_reg.name,
            description: tool_reg.description,
            parameters: tool_reg.parameters,
            metadata:
              Map.put(
                tool_reg.metadata,
                "supports_streaming",
                to_string(tool_reg.supports_streaming)
              ),
            worker_id: request.worker_id
          }
        end)

      case ToolRegistry.register_tools(request.session_id, tool_specs) do
        {:ok, registered_names} ->
          tool_ids =
            Map.new(registered_names, fn name -> {name, "#{request.session_id}:#{name}"} end)

          %RegisterToolsResponse{
            success: true,
            tool_ids: tool_ids,
            error_message: nil
          }

        {:error, reason} ->
          %RegisterToolsResponse{
            success: false,
            tool_ids: %{},
            error_message: format_error(reason)
          }
      end
    else
      {:error, reason} ->
        %RegisterToolsResponse{
          success: false,
          tool_ids: %{},
          error_message: format_error(reason)
        }
    end
  end

  def get_exposed_elixir_tools(%GetExposedElixirToolsRequest{session_id: session_id}, _stream) do
    SLog.debug("GetExposedElixirTools for session #{session_id}")

    tools = ToolRegistry.list_exposed_elixir_tools(session_id)

    tool_specs =
      Enum.map(tools, fn tool ->
        # Convert metadata, handling different value types
        metadata =
          Map.new(tool.metadata, fn
            {k, v} when is_binary(v) or is_atom(v) or is_number(v) ->
              {to_string(k), to_string(v)}

            {k, v} when is_list(v) ->
              # Don't include complex lists in metadata
              {to_string(k), inspect(v)}

            {k, v} ->
              # For other types, use inspect
              {to_string(k), inspect(v)}
          end)

        # Remove parameters from metadata since they're handled separately
        metadata = Map.delete(metadata, "parameters")

        %ToolSpec{
          name: tool.name,
          description: tool.description,
          parameters: encode_parameter_specs(tool.parameters),
          metadata: metadata,
          supports_streaming: Map.get(metadata, "supports_streaming", "false") == "true"
        }
      end)

    %GetExposedElixirToolsResponse{
      tools: tool_specs
    }
  end

  def execute_elixir_tool(%ExecuteElixirToolRequest{} = request, _stream) do
    SLog.info("ExecuteElixirTool: #{request.tool_name} for session #{request.session_id}")

    start_time = System.monotonic_time(:millisecond)

    with {:ok, _session} <- SessionStore.get_session(request.session_id),
         {:ok, tool} <- ToolRegistry.get_tool(request.session_id, request.tool_name),
         :local <- tool.type,
         {:ok, params} <- decode_tool_parameters(request.parameters, %{}),
         {:ok, result} <-
           ToolRegistry.execute_local_tool(request.session_id, request.tool_name, params) do
      execution_time = System.monotonic_time(:millisecond) - start_time
      {encoded_result, binary_result} = encode_tool_result(result)

      %ExecuteElixirToolResponse{
        success: true,
        result: encoded_result,
        binary_result: binary_result || <<>>,
        error_message: nil,
        metadata: %{
          "execution_time" => to_string(execution_time)
        },
        execution_time_ms: execution_time
      }
    else
      :remote ->
        %ExecuteElixirToolResponse{
          success: false,
          result: nil,
          error_message: "Tool #{request.tool_name} is not an Elixir tool",
          metadata: %{},
          execution_time_ms: System.monotonic_time(:millisecond) - start_time
        }

      {:error, reason} ->
        %ExecuteElixirToolResponse{
          success: false,
          result: nil,
          error_message: format_error(reason),
          metadata: %{},
          execution_time_ms: System.monotonic_time(:millisecond) - start_time
        }
    end
  end

  defp encode_parameter_specs(params) when is_list(params) do
    Enum.map(params, fn param ->
      # Convert atom keys to strings
      param =
        case param do
          %{} -> Map.new(param, fn {k, v} -> {to_string(k), v} end)
          _ -> param
        end

      %ParameterSpec{
        name: Map.get(param, "name", ""),
        type: to_string(Map.get(param, "type", "any")),
        description: to_string(Map.get(param, "description", "")),
        required: Map.get(param, "required", false),
        default_value: encode_default_value(Map.get(param, "default")),
        validation_json: Jason.encode!(Map.get(param, "validation", %{}))
      }
    end)
  end

  defp encode_parameter_specs(_), do: []

  defp encode_default_value(nil), do: nil

  defp encode_default_value(value) do
    {any, _binary} = encode_tool_result(value)
    any
  end

  defp encode_tool_result({:binary, data}) when is_binary(data) do
    {empty_any(), data}
  end

  defp encode_tool_result({:binary, data, metadata}) when is_binary(data) do
    {encode_any(metadata), data}
  end

  defp encode_tool_result(value) do
    {encode_any(value), nil}
  end

  defp encode_any(value) do
    case Jason.encode(value) do
      {:ok, json_string} when is_binary(json_string) ->
        %Any{
          type_url: "type.googleapis.com/google.protobuf.StringValue",
          value: json_string
        }

      {:error, _} ->
        %Any{
          type_url: "type.googleapis.com/google.protobuf.StringValue",
          value: inspect(value)
        }
    end
  end

  # Used when we only have an opaque binary payload and no metadata
  defp empty_any do
    %Any{
      type_url: "type.googleapis.com/google.protobuf.StringValue",
      value: "{}"
    }
  end
end
