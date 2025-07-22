defmodule Snakepit.GRPC.ClientImpl do
  @moduledoc """
  Real gRPC client implementation using generated stubs.
  """
  
  require Logger
  alias Snakepit.Bridge
  alias Snakepit.Bridge.Serialization
  
  @default_timeout 30_000
  
  def connect(port) when is_integer(port) do
    connect("localhost:#{port}")
  end
  
  def connect(address) when is_binary(address) do
    opts = [
      interceptors: [GRPC.Logger.Client]
    ]
    
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
    request = Bridge.PingRequest.new(message: message)
    
    timeout = opts[:timeout] || @default_timeout
    call_opts = [timeout: timeout]
    
    case Bridge.SnakepitBridge.Stub.ping(channel, request, call_opts) do
      {:ok, response, _headers} ->
        {:ok, %{
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
    
    session_config = Bridge.SessionConfig.new(
      enable_caching: Map.get(config, :enable_caching, true),
      cache_ttl_seconds: Map.get(config, :cache_ttl_seconds, 60),
      enable_telemetry: Map.get(config, :enable_telemetry, false)
    )
    
    request = Bridge.InitializeSessionRequest.new(
      session_id: session_id,
      metadata: metadata,
      config: session_config
    )
    
    timeout = opts[:timeout] || @default_timeout
    call_opts = [timeout: timeout]
    
    case Bridge.SnakepitBridge.Stub.initialize_session(channel, request, call_opts) do
      {:ok, response, _headers} ->
        {:ok, %{
          success: response.success,
          available_tools: response.available_tools,
          initial_variables: response.initial_variables,
          error_message: response.error_message
        }}
      error ->
        handle_error(error)
    end
  end
  
  def cleanup_session(channel, session_id, force \\ false, opts \\ []) do
    request = Bridge.CleanupSessionRequest.new(
      session_id: session_id,
      force: force
    )
    
    timeout = opts[:timeout] || @default_timeout
    call_opts = [timeout: timeout]
    
    case Bridge.SnakepitBridge.Stub.cleanup_session(channel, request, call_opts) do
      {:ok, response, _headers} ->
        {:ok, %{
          success: response.success,
          resources_cleaned: response.resources_cleaned
        }}
      error ->
        handle_error(error)
    end
  end
  
  def register_variable(channel, session_id, name, type, initial_value, opts \\ []) do
    # Encode value
    {:ok, any_value} = Serialization.encode_any(initial_value, type)
    
    # Convert to protobuf Any
    proto_any = Google.Protobuf.Any.new(
      type_url: any_value.type_url,
      value: any_value.value
    )
    
    # Encode constraints if provided
    constraints_json = case opts[:constraints] do
      nil -> ""
      constraints -> Jason.encode!(constraints)
    end
    
    request = Bridge.RegisterVariableRequest.new(
      session_id: session_id,
      name: to_string(name),
      type: to_string(type),
      initial_value: proto_any,
      constraints: constraints_json,
      metadata: opts[:metadata] || %{}
    )
    
    timeout = opts[:timeout] || @default_timeout
    call_opts = [timeout: timeout]
    
    case Bridge.SnakepitBridge.Stub.register_variable(channel, request, call_opts) do
      {:ok, response, _headers} ->
        if response.variable do
          variable = decode_variable(response.variable)
          {:ok, response.variable_id, variable}
        else
          {:error, "Failed to register variable"}
        end
      error ->
        handle_error(error)
    end
  end
  
  def get_variable(channel, session_id, identifier, opts \\ []) do
    request = if is_binary(identifier) and String.starts_with?(identifier, "var_") do
      Bridge.GetVariableRequest.new(
        session_id: session_id,
        id: identifier
      )
    else
      Bridge.GetVariableRequest.new(
        session_id: session_id,
        name: to_string(identifier)
      )
    end
    
    timeout = opts[:timeout] || @default_timeout
    call_opts = [timeout: timeout]
    
    case Bridge.SnakepitBridge.Stub.get_variable(channel, request, call_opts) do
      {:ok, response, _headers} ->
        if response.variable do
          {:ok, decode_variable(response.variable)}
        else
          {:error, :not_found}
        end
      error ->
        handle_error(error)
    end
  end
  
  def set_variable(channel, session_id, name, value, opts \\ []) do
    # Infer type from current variable
    case get_variable(channel, session_id, name) do
      {:ok, current_var} ->
        # Encode value with the variable's type
        {:ok, any_value} = Serialization.encode_any(value, String.to_atom(current_var.type))
        
        proto_any = Google.Protobuf.Any.new(
          type_url: any_value.type_url,
          value: any_value.value
        )
        
        request = Bridge.SetVariableRequest.new(
          session_id: session_id,
          name: to_string(name),
          value: proto_any,
          metadata: opts[:metadata] || %{}
        )
        
        timeout = opts[:timeout] || @default_timeout
        call_opts = [timeout: timeout]
        
        case Bridge.SnakepitBridge.Stub.set_variable(channel, request, call_opts) do
          {:ok, response, _headers} ->
            if response.success do
              :ok
            else
              {:error, response.error || "Failed to set variable"}
            end
          error ->
            handle_error(error)
        end
        
      error ->
        error
    end
  end
  
  def list_variables(_channel, _session_id, _opts \\ []) do
    # Since there's no ListVariables RPC, we'll use GetVariables with empty list
    # to get all variables (this would need server-side support)
    {:error, :not_implemented}
  end
  
  def watch_variables(channel, session_id, names, opts \\ []) do
    request = Bridge.WatchVariablesRequest.new(
      session_id: session_id,
      variable_names: names,
      include_initial: opts[:include_initial] || false
    )
    
    timeout = opts[:timeout] || 300_000  # 5 minutes for streaming
    call_opts = [timeout: timeout]
    
    case Bridge.SnakepitBridge.Stub.watch_variables(channel, request, call_opts) do
      stream when is_struct(stream, Enumerable.GRPC.Client.Stream) ->
        {:ok, stream}
      error ->
        handle_error(error)
    end
  end
  
  # Helper functions
  
  defp decode_variable(proto_var) do
    # Decode the Any value
    {:ok, value} = if proto_var.value do
      Serialization.decode_any(%{
        type_url: proto_var.value.type_url,
        value: proto_var.value.value
      })
    else
      {:ok, nil}
    end
    
    %{
      id: proto_var.id,
      name: proto_var.name,
      type: String.to_atom(proto_var.type),
      value: value,
      version: proto_var.version,
      source: proto_var.source,
      created_at: proto_var.created_at,
      updated_at: proto_var.updated_at,
      metadata: Map.new(proto_var.metadata),
      constraints: decode_constraints(proto_var.constraints)
    }
  end
  
  defp decode_constraints(""), do: %{}
  defp decode_constraints(nil), do: %{}
  defp decode_constraints(json_str) do
    case Jason.decode(json_str) do
      {:ok, constraints} -> constraints
      _ -> %{}
    end
  end
  
  defp handle_error({:error, %GRPC.RPCError{} = error}) do
    Logger.error("gRPC error: #{inspect(error)}")
    case error.status do
      3 -> {:error, :invalid_argument}
      5 -> {:error, :not_found}
      13 -> {:error, :internal}
      14 -> {:error, :unavailable}
      _ -> {:error, error}
    end
  end
  
  defp handle_error(error), do: error
end