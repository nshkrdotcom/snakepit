defmodule Snakepit.GRPC.BridgeServer do
  @moduledoc """
  gRPC server implementation for the Snakepit Bridge service.

  Handles tool execution and session management through the unified bridge protocol.
  """

  use GRPC.Server, service: Snakepit.Bridge.BridgeService.Service

  alias Snakepit.Bridge.SessionStore
  alias Snakepit.Bridge.ToolRegistry

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

  def execute_tool(%ExecuteToolRequest{} = request, _stream) do
    SLog.info("ExecuteTool: #{request.tool_name} for session #{request.session_id}")

    start_time = System.monotonic_time(:millisecond)

    with {:ok, _session} <- SessionStore.get_session(request.session_id),
         {:ok, tool} <- ToolRegistry.get_tool(request.session_id, request.tool_name),
         {:ok, result} <- execute_tool_handler(tool, request, request.session_id) do
      execution_time = System.monotonic_time(:millisecond) - start_time

      %ExecuteToolResponse{
        success: true,
        result: encode_tool_result(result),
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

  defp execute_tool_handler(%{type: :local} = tool, request, session_id) do
    # Execute local Elixir tool
    params = decode_tool_parameters(request.parameters)
    ToolRegistry.execute_local_tool(session_id, tool.name, params)
  end

  defp execute_tool_handler(%{type: :remote} = tool, request, session_id) do
    # Forward to Python worker
    SLog.debug("Executing remote tool #{tool.name} on worker #{tool.worker_id}")

    with {:ok, worker_port} <- get_worker_port(tool.worker_id),
         {:ok, channel} <- create_worker_channel(worker_port),
         {:ok, result} <- forward_tool_to_worker(channel, request, session_id) do
      # Channel will be cleaned up automatically
      {:ok, result}
    else
      {:error, reason} ->
        SLog.error("Failed to execute remote tool #{tool.name}: #{inspect(reason)}")
        {:error, "Remote tool execution failed: #{inspect(reason)}"}
    end
  end

  defp decode_tool_parameters(params) do
    params
    |> Enum.map(fn {key, any_value} ->
      # Decode the protobuf Any value
      decoded =
        case any_value do
          %Any{type_url: "type.googleapis.com/google.protobuf.StringValue", value: value} ->
            # The value is JSON encoded as bytes, decode it
            case Jason.decode(value) do
              {:ok, decoded} -> decoded
              # Return as-is if not valid JSON
              {:error, _} -> value
            end

          _ ->
            # For other types, try JSON decode or return value as-is
            case Jason.decode(any_value.value) do
              {:ok, decoded} -> decoded
              {:error, _} -> any_value.value
            end
        end

      {key, decoded}
    end)
    |> Map.new()
  end

  # Helper functions for remote tool execution

  defp get_worker_port(worker_id) do
    # For now, try to get from the worker registry
    # In a production implementation, this would be stored in a registry
    case Registry.lookup(Snakepit.Pool.Registry, worker_id) do
      [{pid, _}] when is_pid(pid) ->
        # Try to get port from worker state - this is a simplified approach
        try do
          case GenServer.call(pid, :get_port, 1000) do
            {:ok, port} -> {:ok, port}
            _ -> {:error, "Could not get port from worker"}
          end
        catch
          _exit, _reason -> {:error, "Worker not responding"}
        end

      [] ->
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

  defp forward_tool_to_worker(channel, request, session_id) do
    # Forward the ExecuteToolRequest to the Python worker's gRPC server
    alias Snakepit.Bridge.BridgeService.Stub

    # Create the request to forward to the worker
    worker_request = %ExecuteToolRequest{
      session_id: session_id,
      tool_name: request.tool_name,
      parameters: request.parameters,
      metadata: request.metadata
    }

    try do
      case Stub.execute_tool(channel, worker_request) do
        {:ok, response} ->
          if response.success do
            {:ok, response.result}
          else
            {:error, response.error_message}
          end

        {:error, reason} ->
          {:error, "gRPC call failed: #{inspect(reason)}"}
      end
    rescue
      error -> {:error, "Exception during gRPC call: #{inspect(error)}"}
    end
  end

  def execute_streaming_tool(_request, _stream) do
    raise GRPC.RPCError,
      status: :unimplemented,
      message: "Streaming tool execution not yet implemented"
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: to_string(reason)
  defp format_error({:error, reason}), do: format_error(reason)
  defp format_error({:unknown_type, type}), do: "Unknown type: #{inspect(type)}"
  defp format_error({:invalid_constraints, reason}), do: "Invalid constraints: #{reason}"

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
         params <- decode_tool_parameters(request.parameters),
         {:ok, result} <-
           ToolRegistry.execute_local_tool(request.session_id, request.tool_name, params) do
      execution_time = System.monotonic_time(:millisecond) - start_time

      %ExecuteElixirToolResponse{
        success: true,
        result: encode_tool_result(result),
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
  defp encode_default_value(value), do: encode_tool_result(value)

  defp encode_tool_result(value) do
    # Encode tool results as JSON since we don't know the specific type
    case Jason.encode(value) do
      {:ok, json_string} when is_binary(json_string) ->
        # Ensure the value is properly encoded as bytes
        %Any{
          type_url: "type.googleapis.com/google.protobuf.StringValue",
          # This should already be a binary string
          value: json_string
        }

      {:error, _} ->
        # Fallback: encode as string representation
        %Any{
          type_url: "type.googleapis.com/google.protobuf.StringValue",
          # inspect always returns a string
          value: inspect(value)
        }
    end
  end
end
