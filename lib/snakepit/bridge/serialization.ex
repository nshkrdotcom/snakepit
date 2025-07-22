defmodule Snakepit.Bridge.Serialization do
  @moduledoc """
  Centralized serialization for the bridge protocol.

  This module handles the serialization/deserialization of values to/from
  the protobuf Any type used in the gRPC protocol. It ensures compatibility
  between Elixir and Python sides of the bridge.
  """

  alias Snakepit.Bridge.Variables.Types

  @doc """
  Encode a value to protobuf Any format.

  Returns a map with :type_url and :value (as binary) ready for protobuf Any.
  The value is JSON-encoded and then converted to UTF-8 bytes to match
  the Python implementation.
  """
  def encode_any(value, type) do
    with {:ok, type_module} <- Types.get_type_module(type),
         {:ok, normalized} <- type_module.validate(value) do
      # Convert value to JSON-serializable format
      json_value = to_json_value(normalized, type)

      # Encode to JSON string then to UTF-8 bytes
      json_string = Jason.encode!(json_value)

      any = %{
        type_url: "type.googleapis.com/snakepit.#{type}",
        # This will be encoded as bytes by protobuf
        value: json_string
      }

      {:ok, any}
    end
  rescue
    e in Jason.EncodeError ->
      {:error, "JSON encoding failed: #{Exception.message(e)}"}
  end

  @doc """
  Decode a protobuf Any to a typed value.

  Expects the value field to be a JSON string (as UTF-8 bytes in the protobuf).
  """
  def decode_any(%{type_url: type_url, value: json_bytes} = _any) do
    # Extract type from URL
    type = extract_type_from_url(type_url)

    with {:ok, type_atom} <- parse_type(type),
         json_string <- ensure_string(json_bytes),
         {:ok, json_value} <- Jason.decode(json_string),
         typed_value <- from_json_value(json_value, type_atom),
         {:ok, type_module} <- Types.get_type_module(type_atom),
         {:ok, value} <- type_module.validate(typed_value) do
      {:ok, value}
    else
      {:error, %Jason.DecodeError{} = e} ->
        {:error, "JSON decoding failed: #{Exception.message(e)}"}

      error ->
        error
    end
  end

  @doc """
  Validate a value against type constraints.
  """
  def validate_constraints(value, type, constraints) do
    with {:ok, type_module} <- Types.get_type_module(type) do
      type_module.validate_constraints(value, constraints)
    end
  end

  @doc """
  Parse constraints JSON string into a map.
  """
  def parse_constraints(nil), do: {:ok, %{}}
  def parse_constraints(""), do: {:ok, %{}}

  def parse_constraints(json_string) when is_binary(json_string) do
    case Jason.decode(json_string) do
      {:ok, constraints} -> {:ok, constraints}
      {:error, reason} -> {:error, "Invalid JSON: #{inspect(reason)}"}
    end
  end

  def parse_constraints(constraints) when is_map(constraints), do: {:ok, constraints}

  # Convert Elixir values to JSON-compatible format
  defp to_json_value(value, type) do
    case type do
      :float ->
        # Handle special float values
        cond do
          value == :nan -> "NaN"
          value == :infinity -> "Infinity"
          value == :negative_infinity -> "-Infinity"
          is_number(value) -> value
          true -> value
        end

      _ ->
        # For other types, use as-is (they should already be JSON-compatible)
        value
    end
  end

  # Convert JSON values back to Elixir format
  defp from_json_value(json_value, type) do
    case type do
      :float ->
        # Handle special float values
        case json_value do
          "NaN" -> :nan
          "Infinity" -> :infinity
          "-Infinity" -> :negative_infinity
          value when is_number(value) -> value * 1.0
          value -> value
        end

      _ ->
        # For other types, use as-is
        json_value
    end
  end

  defp ensure_string(value) when is_binary(value), do: value
  defp ensure_string(value), do: to_string(value)

  defp extract_type_from_url(type_url) do
    # Handle both "dspex.variables/type" and "type.googleapis.com/snakepit.type" formats
    cond do
      String.contains?(type_url, "snakepit.") ->
        type_url
        |> String.split("snakepit.")
        |> List.last()

      String.contains?(type_url, "/") ->
        type_url
        |> String.split("/")
        |> List.last()

      true ->
        nil
    end
  end

  defp parse_type("float"), do: {:ok, :float}
  defp parse_type("integer"), do: {:ok, :integer}
  defp parse_type("string"), do: {:ok, :string}
  defp parse_type("boolean"), do: {:ok, :boolean}
  defp parse_type("choice"), do: {:ok, :choice}
  defp parse_type("module"), do: {:ok, :module}
  defp parse_type("embedding"), do: {:ok, :embedding}
  defp parse_type("tensor"), do: {:ok, :tensor}
  defp parse_type(_), do: {:error, :unknown_type}
end
