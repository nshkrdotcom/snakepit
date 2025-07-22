defmodule Snakepit.GRPC.BridgeServer do
  @moduledoc """
  gRPC server implementation for the Snakepit Bridge service.

  Handles variable operations, tool execution, and session management
  through the unified bridge protocol.
  """

  use GRPC.Server, service: Snakepit.Bridge.SnakepitBridge.Service

  alias Snakepit.Bridge.SessionStore
  alias Snakepit.Bridge.Variables.{Variable, Types}

  alias Snakepit.Bridge.{
    PingRequest,
    PingResponse,
    InitializeSessionRequest,
    InitializeSessionResponse,
    CleanupSessionRequest,
    CleanupSessionResponse,
    RegisterVariableRequest,
    RegisterVariableResponse,
    GetVariableRequest,
    GetVariableResponse,
    SetVariableRequest,
    SetVariableResponse,
    BatchGetVariablesRequest,
    BatchGetVariablesResponse,
    BatchSetVariablesRequest,
    BatchSetVariablesResponse,
    OptimizationStatus
  }

  alias Snakepit.Bridge.Variable, as: ProtoVariable

  alias Google.Protobuf.{Any, Timestamp}

  require Logger

  # Health & Session Management

  @impl GRPC.Server
  def ping(%PingRequest{message: message}, _stream) do
    Logger.debug("Ping received: #{message}")

    %PingResponse{
      message: "pong: #{message}",
      server_time: %Timestamp{seconds: System.system_time(:second), nanos: 0}
    }
  end

  @impl GRPC.Server
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
        %InitializeSessionResponse{
          success: false,
          error_message: "Session already exists"
        }

      {:error, reason} ->
        %InitializeSessionResponse{
          success: false,
          error_message: format_error(reason)
        }
    end
  end

  @impl GRPC.Server
  def cleanup_session(%CleanupSessionRequest{session_id: session_id, force: force}, _stream) do
    Logger.info("Cleaning up session: #{session_id}")

    case SessionStore.delete_session(session_id, force: force) do
      :ok ->
        %CleanupSessionResponse{
          success: true,
          resources_cleaned: 1
        }

      {:error, _reason} ->
        %CleanupSessionResponse{
          success: false,
          resources_cleaned: 0
        }
    end
  end

  # Variable Operations

  @impl GRPC.Server
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
      {:error, reason} ->
        %RegisterVariableResponse{
          success: false,
          error_message: format_error(reason)
        }
    end
  end

  @impl GRPC.Server
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

  @impl GRPC.Server
  def set_variable(request, _stream) do
    Logger.debug("SetVariable: session=#{request.session_id}, id=#{request.variable_identifier}")

    # First get the variable to know its type
    case SessionStore.get_variable(request.session_id, request.variable_identifier) do
      {:ok, variable} ->
        case decode_typed_value(request.value, variable.type) do
          {:ok, decoded_value} ->
            case SessionStore.update_variable(
                   request.session_id,
                   request.variable_identifier,
                   decoded_value,
                   request.metadata
                 ) do
              :ok ->
                # Get updated variable for version
                case SessionStore.get_variable(request.session_id, request.variable_identifier) do
                  {:ok, updated} ->
                    %SetVariableResponse{
                      success: true,
                      new_version: updated.version
                    }

                  _ ->
                    %SetVariableResponse{
                      success: true,
                      new_version: variable.version + 1
                    }
                end

              {:error, reason} ->
                %SetVariableResponse{
                  success: false,
                  error_message: format_error(reason)
                }
            end

          {:error, reason} ->
            %SetVariableResponse{
              success: false,
              error_message: format_error(reason)
            }
        end

      {:error, reason} ->
        %SetVariableResponse{
          success: false,
          error_message: format_error(reason)
        }
    end
  end

  @impl GRPC.Server
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

  @impl GRPC.Server
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

  defp decode_any_value(%Any{type_url: _type_url, value: encoded}) do
    case Jason.decode(encoded) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, "Failed to decode value"}
    end
  end

  defp decode_typed_value(%Any{} = any_value, expected_type) do
    with {:ok, decoded} <- decode_any_value(any_value),
         {:ok, validated} <- Types.validate_value(decoded, expected_type) do
      {:ok, validated}
    end
  end

  defp decode_constraints(nil), do: {:ok, %{}}
  defp decode_constraints(""), do: {:ok, %{}}

  defp decode_constraints(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, constraints} when is_map(constraints) ->
        # Convert string keys to atoms
        atomized =
          Enum.reduce(constraints, %{}, fn {k, v}, acc ->
            Map.put(acc, String.to_atom(k), v)
          end)

        {:ok, atomized}

      {:ok, _} ->
        {:error, "Constraints must be a JSON object"}

      {:error, _} ->
        {:error, "Invalid constraints JSON"}
    end
  end

  defp encode_variable(variable) do
    with {:ok, value_any} <- encode_any_value(variable.value, variable.type) do
      proto_var = %ProtoVariable{
        id: variable.id,
        name: to_string(variable.name),
        type: to_string(variable.type),
        value: value_any,
        constraints_json: Jason.encode!(variable.constraints),
        metadata: variable.metadata,
        source: :ELIXIR,
        last_updated_at: %Timestamp{seconds: variable.last_updated_at, nanos: 0},
        version: variable.version,
        optimization_status: encode_optimization_status(variable)
      }

      {:ok, proto_var}
    end
  end

  defp encode_any_value(value, type) do
    # Create a properly typed Any message
    encoded = Jason.encode!(value)

    {:ok,
     %Any{
       type_url: "type.googleapis.com/snakepit.#{type}",
       value: encoded
     }}
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

  defp format_error({:validation_failed, details}) when is_map(details) do
    "Validation failed: #{inspect(details)}"
  end

  defp format_error(reason), do: inspect(reason)
end
