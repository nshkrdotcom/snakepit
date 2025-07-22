defmodule Snakepit.GRPC.Client do
  @moduledoc """
  gRPC client for the unified bridge protocol.
  Delegates to the real implementation when available.
  """

  require Logger

  def connect(port) when is_integer(port) do
    connect("localhost:#{port}")
  end

  def connect(address) when is_binary(address) do
    Snakepit.GRPC.ClientImpl.connect(address)
  end

  def ping(channel, message, opts \\ []) do
    if not Map.get(channel, :mock, false) do
      Snakepit.GRPC.ClientImpl.ping(channel, message, opts)
    else
      # Mock implementation
      {:ok, %{message: "Pong: #{message}", server_time: DateTime.utc_now()}}
    end
  end

  def initialize_session(channel, session_id, config \\ %{}, opts \\ []) do
    if not Map.get(channel, :mock, false) do
      Snakepit.GRPC.ClientImpl.initialize_session(channel, session_id, config, opts)
    else
      # Mock implementation
      {:ok, %{success: true, available_tools: %{}, initial_variables: %{}}}
    end
  end

  def cleanup_session(channel, session_id, force \\ false, opts \\ []) do
    if not Map.get(channel, :mock, false) do
      Snakepit.GRPC.ClientImpl.cleanup_session(channel, session_id, force, opts)
    else
      # Mock implementation  
      {:ok, %{success: true, resources_cleaned: 2}}
    end
  end

  def register_variable(
        channel,
        session_id,
        name,
        type,
        initial_value,
        constraints \\ %{},
        opts \\ []
      ) do
    # Emit telemetry event
    :telemetry.execute(
      [:snakepit, :grpc, :register_variable, :start],
      %{system_time: System.system_time()},
      %{session_id: session_id, name: name, type: type}
    )

    start_time = System.monotonic_time()

    result =
      if not Map.get(channel, :mock, false) do
        # Merge constraints into opts
        full_opts = Keyword.put(opts, :constraints, constraints)

        Snakepit.GRPC.ClientImpl.register_variable(
          channel,
          session_id,
          name,
          type,
          initial_value,
          full_opts
        )
      else
        # Mock implementation
        _request = %{
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
    if not Map.get(channel, :mock, false) do
      Snakepit.GRPC.ClientImpl.get_variable(channel, session_id, identifier, opts)
    else
      # Mock implementation
      {:ok, %{variable: %{id: identifier, name: identifier, type: "float", value: 0.7}}}
    end
  end

  def set_variable(channel, session_id, identifier, value, opts \\ []) do
    if not Map.get(channel, :mock, false) do
      Snakepit.GRPC.ClientImpl.set_variable(channel, session_id, identifier, value, opts)
    else
      # Mock implementation
      {:ok, %{success: true, error_message: "", new_version: 1}}
    end
  end

  def execute_tool(_channel, session_id, tool_name, parameters, opts \\ []) do
    proto_params =
      Enum.into(parameters, %{}, fn {k, v} ->
        {to_string(k), encode_any(v)}
      end)

    _request = %{
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

  def get_info(_channel) do
    # Return mock info for now
    {:ok,
     %{
       version: "1.0.0",
       capabilities: ["tools", "variables", "streaming"]
     }}
  end

  def list_variables(channel, session_id, pattern \\ "*", opts \\ []) do
    if not Map.get(channel, :mock, false) do
      Snakepit.GRPC.ClientImpl.list_variables(channel, session_id, pattern, opts)
    else
      # Mock implementation
      {:ok, %{variables: []}}
    end
  end

  def delete_variable(channel, session_id, identifier, opts \\ []) do
    if not Map.get(channel, :mock, false) do
      Snakepit.GRPC.ClientImpl.delete_variable(channel, session_id, identifier, opts)
    else
      # Mock implementation
      {:ok, %{success: true}}
    end
  end

  def get_session(channel, session_id, opts \\ []) do
    if not Map.get(channel, :mock, false) do
      Snakepit.GRPC.ClientImpl.get_session(channel, session_id, opts)
    else
      # Mock implementation
      {:ok, %{session: %{id: session_id, active: true}}}
    end
  end

  def heartbeat(channel, session_id, opts \\ []) do
    if not Map.get(channel, :mock, false) do
      Snakepit.GRPC.ClientImpl.heartbeat(channel, session_id, opts)
    else
      # Mock implementation
      {:ok, %{success: true}}
    end
  end

  def set_variables(channel, session_id, updates, opts \\ []) do
    if not Map.get(channel, :mock, false) do
      Snakepit.GRPC.ClientImpl.set_variables(channel, session_id, updates, opts)
    else
      # Mock implementation
      results =
        Enum.map(updates, fn update ->
          %{
            identifier: update.identifier,
            success: true,
            error: nil
          }
        end)

      {:ok, %{results: results}}
    end
  end
end
