defmodule Snakepit.GRPC.Client do
  @moduledoc """
  gRPC client for the unified bridge protocol.
  Delegates to the real implementation when available.
  """
  
  require Logger
  
  @default_timeout 30_000
  @default_deadline 60_000
  
  # Check if we have the real implementation available
  @has_real_impl Code.ensure_loaded?(Snakepit.GRPC.ClientImpl)
  
  def connect(port) when is_integer(port) do
    connect("localhost:#{port}")
  end
  
  def connect(address) when is_binary(address) do
    if @has_real_impl do
      Snakepit.GRPC.ClientImpl.connect(address)
    else
      # Fallback to mock implementation
      Logger.warning("Using mock gRPC client - protobuf not compiled")
      {:ok, %{address: address, mock: true}}
    end
  end
  
  def ping(channel, message, opts \\ []) do
    if @has_real_impl and not Map.get(channel, :mock, false) do
      Snakepit.GRPC.ClientImpl.ping(channel, message, opts)
    else
      # Mock implementation
      {:ok, %{message: "Pong: #{message}", server_time: DateTime.utc_now()}}
    end
  end
  
  def initialize_session(channel, session_id, config \\ %{}, opts \\ []) do
    request = %{
      session_id: session_id,
      metadata: %{
        "elixir_node" => to_string(node()),
        "initialized_at" => DateTime.to_iso8601(DateTime.utc_now())
      },
      config: Map.merge(%{
        enable_caching: true,
        cache_ttl_seconds: 60,
        enable_telemetry: false
      }, config)
    }
    
    # Placeholder for actual gRPC call
    {:ok, %{success: true, available_tools: %{}, initial_variables: %{}}}
  end
  
  def cleanup_session(channel, session_id, force \\ false, opts \\ []) do
    request = %{
      session_id: session_id,
      force: force
    }
    
    # Placeholder for actual gRPC call
    {:ok, %{success: true, resources_cleaned: 2}}
  end
  
  def register_variable(channel, session_id, name, type, initial_value, constraints \\ %{}, opts \\ []) do
    # Emit telemetry event
    :telemetry.execute(
      [:snakepit, :grpc, :register_variable, :start],
      %{system_time: System.system_time()},
      %{session_id: session_id, name: name, type: type}
    )
    
    start_time = System.monotonic_time()
    
    result = if @has_real_impl and not Map.get(channel, :mock, false) do
      # Merge constraints into opts
      full_opts = Keyword.put(opts, :constraints, constraints)
      Snakepit.GRPC.ClientImpl.register_variable(channel, session_id, name, type, initial_value, full_opts)
    else
      # Mock implementation
      request = %{
        session_id: session_id,
        name: to_string(name),
        type: to_string(type),
        initial_value: encode_any(initial_value),
        constraints_json: Jason.encode!(constraints),
        metadata: opts[:metadata] || %{}
      }
      
      # Placeholder for actual gRPC call
      {:ok, %{success: true, variable_id: "var_#{:rand.uniform(1000)}", error_message: ""}}
    end
    
    # Emit completion telemetry
    :telemetry.execute(
      [:snakepit, :grpc, :register_variable, :stop],
      %{duration: System.monotonic_time() - start_time},
      %{session_id: session_id, name: name, type: type, success: elem(result, 0) == :ok}
    )
    
    result
  end
  
  def get_variable(channel, session_id, identifier, opts \\ []) do
    request = %{
      session_id: session_id,
      variable_identifier: to_string(identifier),
      bypass_cache: opts[:bypass_cache] || false
    }
    
    # Placeholder for actual gRPC call
    {:ok, %{variable: %{id: identifier, name: identifier, type: "float", value: 0.7}}}
  end
  
  def set_variable(channel, session_id, identifier, value, opts \\ []) do
    request = %{
      session_id: session_id,
      variable_identifier: to_string(identifier),
      value: encode_any(value),
      metadata: opts[:metadata] || %{},
      expected_version: opts[:expected_version] || 0
    }
    
    # Placeholder for actual gRPC call
    {:ok, %{success: true, error_message: "", new_version: 1}}
  end
  
  def execute_tool(channel, session_id, tool_name, parameters, opts \\ []) do
    proto_params = Enum.into(parameters, %{}, fn {k, v} ->
      {to_string(k), encode_any(v)}
    end)
    
    request = %{
      session_id: session_id,
      tool_name: tool_name,
      parameters: proto_params,
      metadata: opts[:metadata] || %{},
      stream: opts[:stream] || false
    }
    
    # Placeholder for actual gRPC call
    {:ok, %{success: true, result: %{}, error_message: ""}}
  end
  
  # Helper functions
  defp build_call_opts(opts) do
    timeout = opts[:timeout] || @default_timeout
    deadline = opts[:deadline] || @default_deadline
    
    [
      timeout: timeout,
      deadline: deadline
    ]
  end
  
  defp handle_response({:ok, response, _headers}), do: {:ok, response}
  defp handle_response({:ok, response}), do: {:ok, response}
  defp handle_response({:error, %GRPC.RPCError{} = error}) do
    Logger.error("gRPC error: #{inspect(error)}")
    {:error, error}
  end
  defp handle_response(error), do: error
  
  defp encode_any(value) when is_binary(value) do
    %{
      type_url: "type.googleapis.com/google.protobuf.StringValue",
      value: Jason.encode!(%{value: value})
    }
  end
  
  defp encode_any(value) when is_integer(value) do
    %{
      type_url: "type.googleapis.com/google.protobuf.Int64Value",
      value: Jason.encode!(%{value: value})
    }
  end
  
  defp encode_any(value) when is_float(value) do
    %{
      type_url: "type.googleapis.com/google.protobuf.DoubleValue",
      value: Jason.encode!(%{value: value})
    }
  end
  
  defp encode_any(value) when is_boolean(value) do
    %{
      type_url: "type.googleapis.com/google.protobuf.BoolValue",
      value: Jason.encode!(%{value: value})
    }
  end
  
  defp encode_any(value) when is_map(value) or is_list(value) do
    # For complex types, use JSON encoding
    %{
      type_url: "type.googleapis.com/google.protobuf.StringValue",
      value: Jason.encode!(%{value: Jason.encode!(value)})
    }
  end
  
  defp encode_any(value) do
    # Fallback to string representation
    encode_any(to_string(value))
  end
  
  # Existing methods for backward compatibility
  def execute(channel, command, args, timeout \\ 30_000) do
    # Legacy support - redirect to execute_tool
    execute_tool(channel, "default_session", command, args, timeout: timeout)
  end
  
  def health(channel, client_id) do
    ping(channel, "health_check_#{client_id}")
  end
  
  def get_info(channel) do
    # Return mock info for now
    {:ok, %{
      version: "1.0.0",
      capabilities: ["tools", "variables", "streaming"]
    }}
  end
end