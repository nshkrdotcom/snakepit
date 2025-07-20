defmodule Snakepit.Bridge.Protocol do
  @moduledoc """
  Wire protocol for Python bridge communication.

  This module handles the encoding and decoding of messages between Elixir and Python
  processes using either JSON or MessagePack protocol with 4-byte length headers for proper framing.

  ## Protocol Format

  Each message consists of:
  1. 4-byte big-endian length header indicating the payload size
  2. Payload (JSON or MessagePack) containing the actual message data

  ## Request Format

      %{
        "id" => integer(),
        "command" => string(),
        "args" => map(),
        "timestamp" => iso8601_string()
      }

  ## Response Format

      # Success
      %{
        "id" => integer(),
        "success" => true,
        "result" => any(),
        "timestamp" => iso8601_string()
      }

      # Error
      %{
        "id" => integer(),
        "success" => false,
        "error" => string(),
        "timestamp" => iso8601_string()
      }

  ## Features

  - Request/response correlation using unique IDs
  - Timestamping for debugging and metrics
  - Structured error handling
  - JSON or MessagePack encoding for performance
  - Length-prefixed framing for reliable message boundaries
  - Protocol version negotiation
  """

  require Logger

  @type request_id :: non_neg_integer()
  @type command :: atom() | String.t()
  @type args :: map()
  @type result :: any()
  @type error_reason :: String.t()
  @type protocol_format :: :json | :msgpack

  # Protocol version constants
  @protocol_json "json"
  @protocol_msgpack "msgpack"

  @doc """
  Encodes a request for sending to the Python bridge.

  Creates a properly formatted request message with a unique ID, command,
  arguments, and timestamp. The message is encoded according to the specified format.

  ## Options

    * `:format` - The encoding format, either `:json` or `:msgpack` (default: `:msgpack`)

  ## Examples

      iex> Snakepit.Bridge.Protocol.encode_request(1, :ping, %{})
      <<binary_data>>

      iex> Snakepit.Bridge.Protocol.encode_request(2, "create_program", %{signature: %{}}, format: :json)
      ~s({"id":2,"command":"create_program","args":{"signature":{}},"timestamp":"2024-01-01T00:00:00Z"})
  """
  @spec encode_request(request_id(), command(), args(), keyword()) :: binary()
  def encode_request(id, command, args, opts \\ []) when is_integer(id) and id >= 0 do
    format = Keyword.get(opts, :format, :msgpack)

    request = %{
      "id" => id,
      "command" => to_string(command),
      "args" => args,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    encode_message(request, format)
  end

  @doc """
  Decodes a response received from the Python bridge.

  Parses response data (JSON or MessagePack) and extracts the request ID, success status,
  and either the result or error information.

  ## Options

    * `:format` - The expected encoding format, either `:json` or `:msgpack` (default: `:msgpack`)

  ## Examples

      iex> json = ~s({"id":1,"success":true,"result":{"status":"ok"}})
      iex> Snakepit.Bridge.Protocol.decode_response(json, format: :json)
      {:ok, 1, %{"status" => "ok"}}

      iex> json = ~s({"id":2,"success":false,"error":"Something went wrong"})
      iex> Snakepit.Bridge.Protocol.decode_response(json, format: :json)
      {:error, 2, "Something went wrong"}
  """
  @spec decode_response(binary(), keyword()) ::
          {:ok, request_id(), result()}
          | {:error, request_id(), error_reason()}
          | {:error, :decode_error}
          | {:error, :malformed_response}
          | {:error, :binary_data}
  def decode_response(data, opts \\ []) when is_binary(data) do
    format = Keyword.get(opts, :format, :msgpack)

    # Security check: reject Erlang term data
    case data do
      <<131, _rest::binary>> ->
        Logger.warning(
          "Received Erlang term data instead of expected format: #{byte_size(data)} bytes - rejecting for security"
        )

        {:error, :binary_data}

      _ ->
        decode_formatted_response(data, format)
    end
  end

  # Private functions

  defp encode_message(message, :json) do
    case Jason.encode(message) do
      {:ok, json} ->
        json

      {:error, reason} ->
        Logger.error("Failed to encode request as JSON: #{inspect(reason)}")
        raise ArgumentError, "Failed to encode request: #{inspect(reason)}"
    end
  end

  defp encode_message(message, :msgpack) do
    case Msgpax.pack(message, iodata: false) do
      {:ok, packed} ->
        packed

      {:error, reason} ->
        Logger.error("Failed to encode request as MessagePack: #{inspect(reason)}")
        raise ArgumentError, "Failed to encode request: #{inspect(reason)}"
    end
  end

  defp decode_formatted_response(data, :json) do
    decode_json_response(data)
  end

  defp decode_formatted_response(data, :msgpack) do
    case Msgpax.unpack(data) do
      {:ok, response} ->
        process_decoded_response(response)

      {:error, %Msgpax.UnpackError{reason: reason}} ->
        Logger.warning("MessagePack decode failed: #{inspect(reason)}")
        {:error, :decode_error}
    end
  end

  defp decode_json_response(data) do
    case Jason.decode(data) do
      {:ok, response} ->
        process_decoded_response(response)

      {:error, %Jason.DecodeError{position: pos, token: token}} ->
        # Provide detailed JSON parsing error info
        data_preview = String.slice(data, 0, 100)

        Logger.warning(
          "JSON decode failed at position #{pos}, token: #{inspect(token)}, data preview: #{inspect(data_preview)}"
        )

        {:error, :decode_error}
    end
  end

  defp process_decoded_response(%{"id" => id, "success" => true, "result" => result})
       when is_integer(id) do
    {:ok, id, result}
  end

  defp process_decoded_response(%{"id" => id, "success" => false, "error" => error})
       when is_integer(id) do
    {:error, id, error}
  end

  defp process_decoded_response(response) when is_map(response) do
    # Try to extract ID for better error correlation
    case Map.get(response, "id") do
      id when is_integer(id) ->
        Logger.warning("Malformed response structure for request #{id}: missing required fields")
        {:error, id, "Malformed response structure"}

      _ ->
        Logger.warning("Response missing request ID: #{inspect(response)}")
        {:error, :malformed_response}
    end
  end

  @doc """
  Encodes a protocol negotiation message.

  Used during process startup to negotiate the wire protocol version.
  """
  @spec encode_protocol_negotiation() :: binary()
  def encode_protocol_negotiation() do
    message = %{
      "type" => "protocol_negotiation",
      "supported" => [@protocol_msgpack, @protocol_json],
      "preferred" => @protocol_msgpack,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    # Always use JSON for negotiation
    case Jason.encode(message) do
      {:ok, json} -> json
      {:error, _} -> raise "Failed to encode protocol negotiation"
    end
  end

  @doc """
  Decodes a protocol negotiation response.

  Returns the selected protocol format.
  """
  @spec decode_protocol_negotiation(binary()) :: {:ok, protocol_format()} | {:error, term()}
  def decode_protocol_negotiation(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"type" => "protocol_selected", "protocol" => protocol}} ->
        case protocol do
          @protocol_json -> {:ok, :json}
          @protocol_msgpack -> {:ok, :msgpack}
          _ -> {:error, :unsupported_protocol}
        end

      {:ok, _} ->
        {:error, :invalid_negotiation_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Validates that a request has all required fields.

  Checks that a request map contains the necessary fields and that they
  have the correct types.

  ## Examples

      iex> request = %{"id" => 1, "command" => "ping", "args" => %{}}
      iex> Snakepit.Bridge.Protocol.validate_request(request)
      :ok

      iex> Snakepit.Bridge.Protocol.validate_request(%{"id" => 1})
      {:error, "Missing required field: command"}
  """
  @spec validate_request(map()) ::
          :ok | {:error, :invalid_command | :invalid_id | :missing_command | :missing_id}
  def validate_request(request) when is_map(request) do
    cond do
      not Map.has_key?(request, "id") ->
        {:error, :missing_id}

      not Map.has_key?(request, "command") ->
        {:error, :missing_command}

      not is_integer(request["id"]) or request["id"] < 0 ->
        {:error, :invalid_id}

      not is_binary(request["command"]) ->
        {:error, :invalid_command}

      # args is optional, defaults to empty map
      true ->
        :ok
    end
  end

  @doc """
  Validates that a response has all required fields.

  Checks that a response map contains the necessary fields for either
  a success or error response.

  ## Examples

      iex> response = %{"id" => 1, "success" => true, "result" => %{}}
      iex> Snakepit.Bridge.Protocol.validate_response(response)
      :ok

      iex> response = %{"id" => 1, "success" => false, "error" => "Failed"}
      iex> Snakepit.Bridge.Protocol.validate_response(response)
      :ok

      iex> Snakepit.Bridge.Protocol.validate_response(%{"id" => 1})
      {:error, "Missing required field: success"}
  """
  @spec validate_response(map()) ::
          :ok
          | {:error,
             :invalid_id
             | :invalid_success
             | :missing_error
             | :missing_id
             | :missing_result
             | :missing_success}
  def validate_response(response) when is_map(response) do
    cond do
      not Map.has_key?(response, "id") ->
        {:error, :missing_id}

      not Map.has_key?(response, "success") ->
        {:error, :missing_success}

      response["success"] == true and not Map.has_key?(response, "result") ->
        {:error, :missing_result}

      response["success"] == false and not Map.has_key?(response, "error") ->
        {:error, :missing_error}

      not is_integer(response["id"]) ->
        {:error, :invalid_id}

      not is_boolean(response["success"]) ->
        {:error, :invalid_success}

      true ->
        :ok
    end
  end

  @doc """
  Creates a standardized error response.

  Generates a properly formatted error response that can be sent back
  to the caller when an error occurs during request processing.

  ## Examples

      iex> Snakepit.Bridge.Protocol.create_error_response(1, "Command failed")
      %{"id" => 1, "success" => false, "error" => "Command failed", "timestamp" => _}
  """
  @spec create_error_response(request_id(), error_reason()) :: map()
  def create_error_response(id, error_reason) when is_integer(id) and is_binary(error_reason) do
    %{
      "id" => id,
      "success" => false,
      "error" => error_reason,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc """
  Creates a standardized success response.

  Generates a properly formatted success response that can be sent back
  to the caller when a request completes successfully.

  ## Examples

      iex> Snakepit.Bridge.Protocol.create_success_response(1, %{"status" => "ok"})
      %{"id" => 1, "success" => true, "result" => %{"status" => "ok"}, "timestamp" => _}
  """
  @spec create_success_response(request_id(), result()) :: map()
  def create_success_response(id, result) when is_integer(id) do
    %{
      "id" => id,
      "success" => true,
      "result" => result,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc """
  Extracts the request ID from a message.

  Safely extracts the request ID from either a request or response message.
  Returns nil if the ID is not present or not valid.

  ## Examples

      iex> Snakepit.Bridge.Protocol.extract_request_id(%{"id" => 42})
      42

      iex> Snakepit.Bridge.Protocol.extract_request_id(%{"command" => "ping"})
      nil
  """
  @spec extract_request_id(map()) :: request_id() | nil
  def extract_request_id(%{"id" => id}) when is_integer(id) and id >= 0, do: id
  def extract_request_id(_), do: nil

  @doc """
  Generates a unique request ID.

  Creates a monotonically increasing request ID that can be used for
  request/response correlation. Uses System.unique_integer for 
  high performance without serialization bottlenecks.
  """
  @spec generate_request_id() :: request_id()
  def generate_request_id do
    System.unique_integer([:positive])
  end
end
