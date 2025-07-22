defmodule Snakepit.GRPC.BridgeServer do
  @moduledoc """
  gRPC server implementation for the Snakepit Bridge service.

  Handles variable operations, tool execution, and session management
  through the unified bridge protocol.
  """

  use GRPC.Server, service: Snakepit.Bridge.BridgeService.Service

  alias Snakepit.Bridge.SessionStore
  alias Snakepit.Bridge.Variables.{Variable, Types}
  alias Snakepit.Bridge.Serialization

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
    RegisterVariableResponse,
    GetVariableRequest,
    GetVariableResponse,
    SetVariableResponse,
    BatchGetVariablesResponse,
    BatchSetVariablesResponse,
    ListVariablesResponse,
    DeleteVariableResponse,
    OptimizationStatus
  }

  alias Snakepit.Bridge.Variable, as: ProtoVariable

  alias Google.Protobuf.{Any, Timestamp}

  require Logger

  # Health & Session Management

  def ping(%PingRequest{message: message}, _stream) do
    Logger.debug("Ping received: #{message}")

    %PingResponse{
      message: "pong: #{message}",
      server_time: %Timestamp{seconds: System.system_time(:second), nanos: 0}
    }
  end

  def initialize_session(request, _stream) do
    Logger.info("Initializing session: #{request.session_id}")

    case SessionStore.create_session(request.session_id, metadata: request.metadata) do
      {:ok, _session} ->
        %InitializeSessionResponse{
          success: true,
          error_message: nil,
          # Stage 2
          available_tools: %{},
          initial_variables: %{}
        }

      {:error, :already_exists} ->
        raise GRPC.RPCError,
          status: :already_exists,
          message: "Session already exists: #{request.session_id}"

      {:error, reason} ->
        raise GRPC.RPCError,
          status: :internal,
          message: format_error(reason)
    end
  end

  def cleanup_session(%CleanupSessionRequest{session_id: session_id, force: _force}, _stream) do
    Logger.info("Cleaning up session: #{session_id}")

    # TODO: Implement force flag when supported by SessionStore
    # SessionStore.delete_session always returns :ok
    SessionStore.delete_session(session_id)

    %CleanupSessionResponse{
      success: true,
      resources_cleaned: 1
    }
  end

  def get_session(%GetSessionRequest{session_id: session_id}, _stream) do
    Logger.debug("GetSession: #{session_id}")

    case SessionStore.get_session(session_id) do
      {:ok, session} ->
        variables = Map.get(session, :variables, %{})
        tools = Map.get(session, :tools, %{})
        metadata = Map.get(session, :metadata, %{})
        
        variable_count = map_size(variables)
        tool_count = map_size(tools)

        %GetSessionResponse{
          session_id: session_id,
          metadata: metadata,
          created_at: %Timestamp{seconds: session.created_at, nanos: 0},
          variable_count: variable_count,
          tool_count: tool_count
        }

      {:error, :not_found} ->
        raise GRPC.RPCError,
          status: :not_found,
          message: "Session not found: #{session_id}"
    end
  end

  def heartbeat(%HeartbeatRequest{session_id: session_id, client_time: _client_time}, _stream) do
    Logger.debug("Heartbeat: #{session_id}")

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

  # Variable Operations

  def register_variable(request, _stream) do
    Logger.debug("RegisterVariable: session=#{request.session_id}, name=#{request.name}")

    with {:ok, initial_value} <- decode_any_value(request.initial_value),
         {:ok, constraints} <- decode_constraints(request.constraints_json),
         {:ok, var_id} <-
           SessionStore.register_variable(
             request.session_id,
             request.name,
             String.to_atom(request.type),
             initial_value,
             constraints: constraints,
             metadata: request.metadata
           ) do
      %RegisterVariableResponse{
        success: true,
        variable_id: var_id
      }
    else
      {:error, {:validation_failed, _} = reason} ->
        raise GRPC.RPCError,
          status: :invalid_argument,
          message: format_error(reason)

      {:error, :session_not_found} ->
        raise GRPC.RPCError,
          status: :not_found,
          message: "Session not found: #{request.session_id}"

      {:error, reason} ->
        raise GRPC.RPCError,
          status: :internal,
          message: format_error(reason)
    end
  end

  def get_variable(
        %GetVariableRequest{session_id: session_id, variable_identifier: identifier},
        _stream
      ) do
    Logger.debug("GetVariable: session=#{session_id}, id=#{identifier}")

    case SessionStore.get_variable(session_id, identifier) do
      {:ok, variable} ->
        case encode_variable(variable) do
          {:ok, proto_var} ->
            %GetVariableResponse{
              variable: proto_var,
              # TODO: Implement caching in Stage 3
              from_cache: false
            }

          {:error, reason} ->
            Logger.error("Failed to encode variable: #{inspect(reason)}")
            raise GRPC.RPCError, status: :internal, message: format_error(reason)
        end

      {:error, :not_found} ->
        raise GRPC.RPCError, status: :not_found, message: "Variable not found: #{identifier}"

      {:error, :session_not_found} ->
        raise GRPC.RPCError, status: :not_found, message: "Session not found: #{session_id}"

      {:error, reason} ->
        raise GRPC.RPCError, status: :internal, message: format_error(reason)
    end
  end

  def set_variable(request, _stream) do
    Logger.debug("SetVariable: session=#{request.session_id}, id=#{request.variable_identifier}")

    # First get the variable to know its type
    with {:ok, variable} <-
           SessionStore.get_variable(request.session_id, request.variable_identifier),
         {:ok, decoded_value} <- decode_typed_value(request.value, variable.type),
         :ok <-
           SessionStore.update_variable(
             request.session_id,
             request.variable_identifier,
             decoded_value,
             request.metadata
           ) do
      # Get updated variable for version
      new_version =
        case SessionStore.get_variable(request.session_id, request.variable_identifier) do
          {:ok, updated} -> updated.version
          _ -> variable.version + 1
        end

      %SetVariableResponse{
        success: true,
        new_version: new_version
      }
    else
      {:error, :not_found} ->
        raise GRPC.RPCError,
          status: :not_found,
          message: "Variable not found: #{request.variable_identifier}"

      {:error, :session_not_found} ->
        raise GRPC.RPCError,
          status: :not_found,
          message: "Session not found: #{request.session_id}"

      {:error, {:validation_failed, _} = reason} ->
        raise GRPC.RPCError,
          status: :invalid_argument,
          message: format_error(reason)

      {:error, reason} ->
        raise GRPC.RPCError,
          status: :internal,
          message: format_error(reason)
    end
  end

  def get_variables(request, _stream) do
    Logger.debug(
      "GetVariables: session=#{request.session_id}, count=#{length(request.variable_identifiers)}"
    )

    case SessionStore.get_variables(request.session_id, request.variable_identifiers) do
      {:ok, %{found: found, missing: missing}} ->
        # Encode all found variables
        encoded_vars =
          Enum.reduce(found, %{}, fn {id, variable}, acc ->
            case encode_variable(variable) do
              {:ok, proto_var} -> Map.put(acc, id, proto_var)
              # Skip encoding errors
              {:error, _} -> acc
            end
          end)

        %BatchGetVariablesResponse{
          variables: encoded_vars,
          missing_variables: missing
        }

      {:error, :session_not_found} ->
        raise GRPC.RPCError,
          status: :not_found,
          message: "Session not found: #{request.session_id}"

      {:error, reason} ->
        raise GRPC.RPCError, status: :internal, message: format_error(reason)
    end
  end

  def set_variables(request, _stream) do
    Logger.debug(
      "SetVariables: session=#{request.session_id}, count=#{map_size(request.updates)}"
    )

    # Decode all values first
    case decode_updates_map(request.session_id, request.updates) do
      {:ok, decoded_updates} ->
        opts = [
          atomic: request.atomic,
          metadata: request.metadata
        ]

        case SessionStore.update_variables(request.session_id, decoded_updates, opts) do
          {:ok, results} ->
            # Convert results to response format
            errors =
              Enum.reduce(results, %{}, fn {id, result}, acc ->
                case result do
                  :ok -> acc
                  {:error, reason} -> Map.put(acc, id, format_error(reason))
                end
              end)

            # Get new versions for successful updates
            new_versions =
              Enum.reduce(results, %{}, fn {id, result}, acc ->
                case result do
                  :ok ->
                    case SessionStore.get_variable(request.session_id, id) do
                      {:ok, var} -> Map.put(acc, id, var.version)
                      _ -> acc
                    end

                  _ ->
                    acc
                end
              end)

            %BatchSetVariablesResponse{
              success: map_size(errors) == 0,
              errors: errors,
              new_versions: new_versions
            }

          {:error, {:validation_failed, errors}} ->
            # Convert validation errors
            error_map =
              Enum.reduce(errors, %{}, fn {id, reason}, acc ->
                Map.put(acc, id, format_error(reason))
              end)

            %BatchSetVariablesResponse{
              success: false,
              errors: error_map,
              new_versions: %{}
            }

          {:error, reason} ->
            raise GRPC.RPCError, status: :internal, message: format_error(reason)
        end

      {:error, reason} ->
        raise GRPC.RPCError, status: :invalid_argument, message: format_error(reason)
    end
  end

  def list_variables(request, _stream) do
    Logger.debug("ListVariables: session=#{request.session_id}")

    case SessionStore.get_session(request.session_id) do
      {:ok, session} ->
        # Apply pattern filter if provided
        variables =
          if request.pattern && request.pattern != "" do
            pattern = String.replace(request.pattern, "*", ".*")
            regex = Regex.compile!(pattern)

            session.variables
            |> Map.values()
            |> Enum.filter(fn var ->
              Regex.match?(regex, to_string(var.name))
            end)
          else
            Map.values(session.variables)
          end

        # Encode all variables
        encoded_vars =
          Enum.reduce(variables, [], fn variable, acc ->
            case encode_variable(variable) do
              {:ok, proto_var} -> [proto_var | acc]
              # Skip encoding errors
              {:error, _} -> acc
            end
          end)
          |> Enum.reverse()

        %ListVariablesResponse{
          variables: encoded_vars
        }

      {:error, :not_found} ->
        raise GRPC.RPCError,
          status: :not_found,
          message: "Session not found: #{request.session_id}"
    end
  end

  def delete_variable(request, _stream) do
    Logger.debug(
      "DeleteVariable: session=#{request.session_id}, id=#{request.variable_identifier}"
    )

    case SessionStore.delete_variable(request.session_id, request.variable_identifier) do
      :ok ->
        %DeleteVariableResponse{
          success: true
        }

      {:error, :not_found} ->
        raise GRPC.RPCError,
          status: :not_found,
          message: "Variable not found: #{request.variable_identifier}"

      {:error, :session_not_found} ->
        raise GRPC.RPCError,
          status: :not_found,
          message: "Session not found: #{request.session_id}"

      {:error, reason} ->
        raise GRPC.RPCError,
          status: :internal,
          message: format_error(reason)
    end
  end

  # TODO: Implement remaining handlers
  def execute_tool(_request, _stream) do
    raise GRPC.RPCError, status: :unimplemented, message: "Tool execution not yet implemented"
  end

  def execute_streaming_tool(_request, _stream) do
    raise GRPC.RPCError,
      status: :unimplemented,
      message: "Streaming tool execution not yet implemented"
  end

  def watch_variables(_request, _stream) do
    raise GRPC.RPCError,
      status: :unimplemented,
      message: "Variable watching not yet implemented (Stage 3)"
  end

  # Encoding/Decoding Helpers

  defp decode_any_value(%Any{} = any_value) do
    Serialization.decode_any(any_value)
  end

  defp decode_typed_value(%Any{} = any_value, expected_type) do
    with {:ok, decoded} <- Serialization.decode_any(any_value),
         {:ok, validated} <- Types.validate_value(decoded, expected_type) do
      {:ok, validated}
    end
  end

  defp decode_constraints(json) do
    case Serialization.parse_constraints(json) do
      {:ok, constraints} ->
        # Convert string keys to atoms
        atomized =
          Enum.reduce(constraints, %{}, fn {k, v}, acc ->
            Map.put(acc, String.to_atom(k), v)
          end)

        {:ok, atomized}

      {:error, reason} ->
        {:error, {:invalid_constraints, reason}}
    end
  end

  defp encode_variable(variable, default_source \\ :ELIXIR) do
    with {:ok, value_any} <- encode_any_value(variable.value, variable.type) do
      # Check metadata for source, falling back to default
      source =
        case variable.metadata["source"] do
          "python" -> :PYTHON
          "elixir" -> :ELIXIR
          "PYTHON" -> :PYTHON
          "ELIXIR" -> :ELIXIR
          nil -> default_source
          _ -> default_source
        end

      proto_var = %ProtoVariable{
        id: variable.id,
        name: to_string(variable.name),
        type: to_string(variable.type),
        value: value_any,
        constraints_json: Jason.encode!(variable.constraints),
        metadata: variable.metadata,
        source: source,
        last_updated_at: %Timestamp{seconds: variable.last_updated_at, nanos: 0},
        version: variable.version,
        optimization_status: encode_optimization_status(variable)
      }

      {:ok, proto_var}
    end
  end

  defp encode_any_value(value, type) do
    case Serialization.encode_any(value, type) do
      {:ok, %{type_url: type_url, value: encoded_value}} ->
        {:ok,
         %Any{
           type_url: type_url,
           value: encoded_value
         }}

      {:error, reason} ->
        {:error, "Failed to encode value: #{inspect(reason)}"}
    end
  end

  defp encode_optimization_status(variable) do
    if Variable.optimizing?(variable) do
      %OptimizationStatus{
        optimizing: true,
        optimizer_id: variable.optimization_status.optimizer_id || "",
        started_at:
          if(variable.optimization_status.started_at,
            do: %Timestamp{seconds: variable.optimization_status.started_at, nanos: 0},
            else: nil
          )
      }
    else
      %OptimizationStatus{
        optimizing: false
      }
    end
  end

  defp decode_updates_map(session_id, updates) do
    # First get variable types for decoding
    identifiers = Map.keys(updates)

    case SessionStore.get_variables(session_id, identifiers) do
      {:ok, %{found: found}} ->
        decoded =
          Enum.reduce_while(updates, {:ok, %{}}, fn {id, any_val}, {:ok, acc} ->
            case Map.get(found, to_string(id)) do
              nil ->
                {:halt, {:error, "Variable not found: #{id}"}}

              variable ->
                case decode_typed_value(any_val, variable.type) do
                  {:ok, value} -> {:cont, {:ok, Map.put(acc, id, value)}}
                  {:error, reason} -> {:halt, {:error, reason}}
                end
            end
          end)

        decoded

      {:error, reason} ->
        {:error, reason}
    end
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
end
