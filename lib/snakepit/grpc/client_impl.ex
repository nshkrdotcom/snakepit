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
           initial_variables: response.initial_variables,
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

  def register_variable(channel, session_id, name, type, initial_value, opts \\ []) do
    require Logger
    # Encode value
    case Serialization.encode_any(initial_value, type) do
      {:ok, any_value, _binary_data} ->
        # Convert to protobuf Any
        proto_any = %Google.Protobuf.Any{
          type_url: any_value.type_url,
          value: any_value.value
        }

        # Encode constraints if provided
        constraints_json =
          case opts[:constraints] do
            nil -> ""
            constraints -> Jason.encode!(constraints)
          end

        request = %Bridge.RegisterVariableRequest{
          session_id: session_id,
          name: to_string(name),
          type: to_string(type),
          initial_value: proto_any,
          constraints_json: constraints_json,
          metadata: opts[:metadata] || %{}
        }

        timeout = opts[:timeout] || @default_timeout
        call_opts = [timeout: timeout]

        result = Bridge.BridgeService.Stub.register_variable(channel, request, call_opts)

        case result do
          {:ok, response, _headers} ->
            Logger.debug("Got response: #{inspect(response)}")

            if response.success do
              {:ok, %{success: true}}
            else
              {:error, response.error_message || "Failed to register variable"}
            end

          {:ok, response} ->
            # The stub is returning just {:ok, response} without headers
            if response.success do
              {:ok, %{success: true}}
            else
              {:error, response.error_message || "Failed to register variable"}
            end

          error ->
            handle_error(error)
        end

      error ->
        error
    end
  end

  def get_variable(channel, session_id, identifier, opts \\ []) do
    request = %Bridge.GetVariableRequest{
      session_id: session_id,
      variable_identifier: to_string(identifier),
      bypass_cache: opts[:bypass_cache] || false
    }

    timeout = opts[:timeout] || @default_timeout
    call_opts = [timeout: timeout]

    case Bridge.BridgeService.Stub.get_variable(channel, request, call_opts) do
      {:ok, response, _headers} ->
        if response.variable do
          {:ok, decode_variable(response.variable)}
        else
          {:error, :not_found}
        end

      {:ok, response} ->
        # Handle 2-tuple response
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
        # Encode value with the variable's type (type is already an atom)
        case Serialization.encode_any(value, current_var.type) do
          {:ok, any_value, _binary_data} ->
            proto_any = %Google.Protobuf.Any{
              type_url: any_value.type_url,
              value: any_value.value
            }

            request = %Bridge.SetVariableRequest{
              session_id: session_id,
              variable_identifier: to_string(name),
              value: proto_any,
              metadata: opts[:metadata] || %{},
              expected_version: opts[:expected_version] || 0
            }

            timeout = opts[:timeout] || @default_timeout
            call_opts = [timeout: timeout]

            case Bridge.BridgeService.Stub.set_variable(channel, request, call_opts) do
              {:ok, response, _headers} ->
                if response.success do
                  {:ok, %{success: true}}
                else
                  {:error, response.error || "Failed to set variable"}
                end

              {:ok, response} ->
                # Handle 2-tuple response
                if response.success do
                  {:ok, %{success: true}}
                else
                  {:error, response.error || "Failed to set variable"}
                end

              error ->
                handle_error(error)
            end

          error ->
            error
        end

      error ->
        error
    end
  end

  def list_variables(channel, session_id, pattern \\ "*", opts \\ []) do
    request = %Bridge.ListVariablesRequest{
      session_id: session_id,
      pattern: pattern
    }

    timeout = opts[:timeout] || @default_timeout
    call_opts = [timeout: timeout]

    case Bridge.BridgeService.Stub.list_variables(channel, request, call_opts) do
      {:ok, response, _headers} ->
        variables = Enum.map(response.variables, &decode_variable/1)
        {:ok, %{variables: variables}}

      {:ok, response} ->
        # Handle 2-tuple response
        variables = Enum.map(response.variables, &decode_variable/1)
        {:ok, %{variables: variables}}

      error ->
        handle_error(error)
    end
  end

  def delete_variable(channel, session_id, identifier, opts \\ []) do
    request = %Bridge.DeleteVariableRequest{
      session_id: session_id,
      variable_identifier: to_string(identifier)
    }

    timeout = opts[:timeout] || @default_timeout
    call_opts = [timeout: timeout]

    case Bridge.BridgeService.Stub.delete_variable(channel, request, call_opts) do
      {:ok, response, _headers} ->
        if response.success do
          {:ok, %{success: true}}
        else
          {:error, response.error_message || "Failed to delete variable"}
        end

      {:ok, response} ->
        # Handle 2-tuple response
        if response.success do
          {:ok, %{success: true}}
        else
          {:error, response.error_message || "Failed to delete variable"}
        end

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

  def set_variables(channel, session_id, updates, opts \\ []) do
    # Convert updates to map format expected by proto
    updates_map =
      Enum.into(updates, %{}, fn update ->
        # Get current type for encoding
        {:ok, current_var} = get_variable(channel, session_id, update.identifier.name)
        {:ok, any_value, _binary_data} = Serialization.encode_any(update.value, current_var.type)

        {update.identifier.name,
         %Google.Protobuf.Any{
           type_url: any_value.type_url,
           value: any_value.value
         }}
      end)

    request = %Bridge.BatchSetVariablesRequest{
      session_id: session_id,
      updates: updates_map,
      metadata: opts[:metadata] || %{},
      atomic: opts[:atomic] || false
    }

    timeout = opts[:timeout] || @default_timeout
    call_opts = [timeout: timeout]

    case Bridge.BridgeService.Stub.set_variables(channel, request, call_opts) do
      {:ok, response, _headers} ->
        handle_batch_response(response, updates)

      {:ok, response} ->
        # Handle 2-tuple response
        handle_batch_response(response, updates)

      error ->
        handle_error(error)
    end
  end

  defp handle_batch_response(response, updates) do
    if response.success do
      # Convert the response to expected format
      results =
        Enum.map(updates, fn update ->
          error = Map.get(response.errors || %{}, update.identifier.name)

          %{
            identifier: update.identifier,
            success: is_nil(error),
            error: error
          }
        end)

      {:ok, %{results: results}}
    else
      {:error, "Batch update failed"}
    end
  end

  def watch_variables(channel, session_id, names, opts \\ []) do
    request = %Bridge.WatchVariablesRequest{
      session_id: session_id,
      variable_identifiers: names,
      include_initial_values: opts[:include_initial] || false
    }

    # 5 minutes for streaming
    timeout = opts[:timeout] || 300_000
    call_opts = [timeout: timeout]

    case Bridge.BridgeService.Stub.watch_variables(channel, request, call_opts) do
      stream when is_struct(stream, Enumerable.GRPC.Client.Stream) ->
        {:ok, stream}

      error ->
        handle_error(error)
    end
  end

  def execute_tool(channel, session_id, tool_name, parameters, opts \\ []) do
    # Convert Elixir terms to protobuf Any messages
    proto_params_result =
      Enum.reduce_while(parameters, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
        case infer_and_encode_any(v) do
          {:ok, proto_any} -> {:cont, {:ok, Map.put(acc, to_string(k), proto_any)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with {:ok, proto_params} <- proto_params_result do
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
  end

  def execute_streaming_tool(channel, session_id, tool_name, parameters, opts \\ []) do
    # Convert Elixir terms to protobuf Any messages
    Logger.info("[ClientImpl] execute_streaming_tool called: #{tool_name}")

    with {:ok, proto_params} <- encode_parameters(parameters) do
      request = %Bridge.ExecuteToolRequest{
        session_id: session_id,
        tool_name: tool_name,
        parameters: proto_params,
        stream: true
      }

      timeout = opts[:timeout] || 300_000
      call_opts = [timeout: timeout]

      # This call returns {:ok, Stream} or {:error, reason}
      Logger.info("[ClientImpl] Calling Bridge.BridgeService.Stub.execute_streaming_tool")
      result = Bridge.BridgeService.Stub.execute_streaming_tool(channel, request, call_opts)
      Logger.info("[ClientImpl] Stub returned: #{inspect(result)}")
      result
    end
  end

  # Helper functions

  defp decode_variable(proto_var) do
    # Decode the Any value
    {:ok, value} =
      if proto_var.value do
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
      # Not in proto
      created_at: nil,
      updated_at: proto_var.last_updated_at,
      metadata: Map.new(proto_var.metadata),
      constraints: decode_constraints(proto_var.constraints_json)
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

  # Helper to infer type and encode to Google.Protobuf.Any
  defp infer_and_encode_any(value) do
    type = Snakepit.Bridge.Variables.Types.infer_type(value)

    # For complex types that would be encoded as :string, we need to handle them specially
    if type == :string and
         (is_map(value) or (is_list(value) and not Enum.all?(value, &is_number/1))) do
      # Encode complex structures as JSON strings
      json_value = Jason.encode!(value)

      with {:ok, any_struct, _binary_data} <- Serialization.encode_any(json_value, :string) do
        {:ok, %Google.Protobuf.Any{type_url: any_struct.type_url, value: any_struct.value}}
      end
    else
      # Use the serialization module for other types
      with {:ok, any_struct, _binary_data} <- Serialization.encode_any(value, type) do
        {:ok, %Google.Protobuf.Any{type_url: any_struct.type_url, value: any_struct.value}}
      end
    end
  end

  defp handle_tool_response(%Bridge.ExecuteToolResponse{success: true, result: any_result}) do
    # Use the centralized decoder - this is the correct approach
    Serialization.decode_any(any_result)
  end

  defp handle_tool_response(%Bridge.ExecuteToolResponse{success: false, error_message: error}) do
    {:error, error}
  end

  defp encode_parameters(parameters) do
    Enum.reduce_while(parameters, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      case infer_and_encode_any(v) do
        {:ok, proto_any} -> {:cont, {:ok, Map.put(acc, to_string(k), proto_any)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
