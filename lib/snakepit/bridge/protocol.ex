defmodule Snakepit.Bridge.Protocol do
  @moduledoc """
  Wire protocol for Python bridge communication.

  This module handles the encoding and decoding of messages between Elixir and Python
  processes using a JSON-based protocol with 4-byte length headers for proper framing.

  ## Protocol Format

  Each message consists of:
  1. 4-byte big-endian length header indicating the JSON payload size
  2. JSON payload containing the actual message data

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
  - JSON encoding for cross-language compatibility
  - Length-prefixed framing for reliable message boundaries
  """

  require Logger

  @type request_id :: non_neg_integer()
  @type command :: atom() | String.t()
  @type args :: map()
  @type result :: any()
  @type error_reason :: String.t()

  @doc """
  Encodes a request for sending to the Python bridge.

  Creates a properly formatted request message with a unique ID, command,
  arguments, and timestamp. The message is encoded as JSON for transmission.

  ## Examples

      iex> Snakepit.Bridge.Protocol.encode_request(1, :ping, %{})
      ~s({"id":1,"command":"ping","args":{},"timestamp":"2024-01-01T00:00:00Z"})

      iex> Snakepit.Bridge.Protocol.encode_request(2, "create_program", %{signature: %{}})
      ~s({"id":2,"command":"create_program","args":{"signature":{}},"timestamp":"2024-01-01T00:00:00Z"})
  """
  @spec encode_request(request_id(), command(), args()) :: binary()
  def encode_request(id, command, args) when is_integer(id) and id >= 0 do
    request = %{
      "id" => id,
      "command" => to_string(command),
      "args" => args,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case Jason.encode(request) do
      {:ok, json} ->
        json

      {:error, reason} ->
        Logger.error("Failed to encode request: #{inspect(reason)}")
        raise ArgumentError, "Failed to encode request: #{inspect(reason)}"
    end
  end

  @doc """
  Decodes a response received from the Python bridge.

  Parses JSON response data and extracts the request ID, success status,
  and either the result or error information.

  ## Examples

      iex> json = ~s({"id":1,"success":true,"result":{"status":"ok"}})
      iex> Snakepit.Bridge.Protocol.decode_response(json)
      {:ok, 1, %{"status" => "ok"}}

      iex> json = ~s({"id":2,"success":false,"error":"Something went wrong"})
      iex> Snakepit.Bridge.Protocol.decode_response(json)
      {:error, 2, "Something went wrong"}

      iex> Snakepit.Bridge.Protocol.decode_response("invalid json")
      {:error, :decode_error}
  """
  @spec decode_response(binary()) ::
          {:ok, request_id(), result()}
          | {:error, request_id(), error_reason()}
          | {:error, :decode_error}
          | {:error, :malformed_response}
          | {:error, :binary_data}
  def decode_response(data) when is_binary(data) do
    # Only accept JSON data - reject any Erlang term data for security
    case data do
      <<131, _rest::binary>> ->
        Logger.warning(
          "Received Erlang term data instead of JSON: #{byte_size(data)} bytes - rejecting for security"
        )

        {:error, :binary_data}

      _ ->
        decode_json_response(data)
    end
  end

  defp decode_json_response(data) do
    case Jason.decode(data) do
      {:ok, %{"id" => id, "success" => true, "result" => result}} when is_integer(id) ->
        {:ok, id, result}

      {:ok, %{"id" => id, "success" => false, "error" => error}} when is_integer(id) ->
        {:error, id, error}

      {:ok, response} when is_map(response) ->
        # Try to extract ID for better error correlation
        case Map.get(response, "id") do
          id when is_integer(id) ->
            Logger.warning(
              "Malformed response structure for request #{id}: missing required fields"
            )

            {:error, id, "Malformed response structure"}

          _ ->
            Logger.warning("Response missing request ID: #{inspect(response)}")
            {:error, :malformed_response}
        end

      {:error, %Jason.DecodeError{position: pos, token: token}} ->
        # Provide detailed JSON parsing error info
        data_preview = String.slice(data, 0, 100)

        Logger.warning(
          "JSON decode failed at position #{pos}, token: #{inspect(token)}, data preview: #{inspect(data_preview)}"
        )

        {:error, :decode_error}
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
