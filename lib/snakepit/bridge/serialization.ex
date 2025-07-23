defmodule Snakepit.Bridge.Serialization do
  @moduledoc """
  Centralized serialization for the bridge protocol.

  This module handles the serialization/deserialization of values to/from
  the protobuf Any type used in the gRPC protocol. It ensures compatibility
  between Elixir and Python sides of the bridge.

  ## Binary Serialization

  For large data (tensors, embeddings), this module can use binary serialization
  instead of JSON when the data exceeds a size threshold. This significantly
  improves performance for numerical arrays.
  """

  alias Snakepit.Bridge.Variables.Types

  # Size threshold for using binary serialization (10KB)
  @binary_threshold 10_240

  @doc """
  Encode a value to protobuf Any format with optional binary serialization.

  Returns a tuple {:ok, any_map, binary_data} where:
  - any_map: map with :type_url and :value for protobuf Any
  - binary_data: optional binary data if value exceeds threshold

  For large tensor/embedding data, returns minimal JSON metadata in Any
  and the actual data as binary.
  """
  def encode_any(value, type) do
    with {:ok, type_module} <- Types.get_type_module(type),
         {:ok, normalized} <- type_module.validate(value) do
      # Check if we should use binary serialization
      case should_use_binary?(normalized, type) do
        true ->
          encode_with_binary(normalized, type)

        false ->
          encode_as_json(normalized, type)
      end
    end
  rescue
    e in Jason.EncodeError ->
      {:error, "JSON encoding failed: #{Exception.message(e)}"}
  end

  # Original JSON-only encoding for backward compatibility
  defp encode_as_json(value, type) do
    # Convert value to JSON-serializable format
    json_value = to_json_value(value, type)

    # Encode to JSON string then to UTF-8 bytes
    json_string = Jason.encode!(json_value)

    any = %{
      type_url: "type.googleapis.com/snakepit.#{type}",
      # This will be encoded as bytes by protobuf
      value: json_string
    }

    {:ok, any, nil}
  end

  # Binary encoding for large data
  defp encode_with_binary(value, type) when type in [:tensor, :embedding] do
    # Extract shape and data
    {shape, data} =
      case type do
        :tensor ->
          {Map.get(value, :shape, []), Map.get(value, :data, [])}

        :embedding ->
          {[length(value)], value}
      end

    # Create metadata for Any field
    metadata = %{
      "shape" => shape,
      "dtype" => "float32",
      "binary_format" => "erlang_binary",
      "type" => to_string(type)
    }

    json_string = Jason.encode!(metadata)

    any = %{
      type_url: "type.googleapis.com/snakepit.#{type}.binary",
      value: json_string
    }

    # Convert data to binary
    binary_data = :erlang.term_to_binary(data)

    {:ok, any, binary_data}
  end

  defp encode_with_binary(value, type) do
    # Fallback to JSON for non-tensor/embedding types
    encode_as_json(value, type)
  end

  # Check if data is large enough to warrant binary serialization
  defp should_use_binary?(value, type) when type in [:tensor, :embedding] do
    estimated_size =
      case type do
        :tensor ->
          data = Map.get(value, :data, [])
          # Assume 8 bytes per float
          length(data) * 8

        :embedding ->
          length(value) * 8
      end

    estimated_size > @binary_threshold
  end

  defp should_use_binary?(_value, _type), do: false

  @doc """
  Decode a protobuf Any to a typed value with optional binary data.

  Handles both JSON-encoded values and binary-encoded large data.
  """
  def decode_any(%{type_url: type_url, value: json_bytes} = _any, binary_data \\ nil) do
    # Check if this is a binary-encoded value
    if String.ends_with?(type_url, ".binary") and binary_data != nil do
      decode_with_binary(type_url, json_bytes, binary_data)
    else
      # Original JSON decoding
      decode_as_json(type_url, json_bytes)
    end
  end

  defp decode_as_json(type_url, json_bytes) do
    # Extract type from URL
    type = extract_type_from_url(type_url)

    with {:ok, type_atom} <- parse_type(type) do
      # For map and list, we just decode the JSON directly.
      if type_atom in [:map, :list] do
        Jason.decode(ensure_string(json_bytes))
      else
        # Standard type handling for others
        with json_string <- ensure_string(json_bytes),
             {:ok, json_value} <- Jason.decode(json_string),
             typed_value <- from_json_value(json_value, type_atom),
             {:ok, type_module} <- Types.get_type_module(type_atom),
             {:ok, value} <- type_module.validate(typed_value) do
          {:ok, value}
        else
          error -> error
        end
      end
    else
      error -> error
    end
  end

  defp decode_with_binary(type_url, metadata_bytes, binary_data) do
    # Extract base type (remove .binary suffix)
    base_type =
      type_url
      |> extract_type_from_url()
      |> String.replace(".binary", "")

    with {:ok, type_atom} <- parse_type(base_type),
         json_string <- ensure_string(metadata_bytes),
         {:ok, metadata} <- Jason.decode(json_string),
         data <- :erlang.binary_to_term(binary_data),
         value <- reconstruct_value(type_atom, metadata, data),
         {:ok, type_module} <- Types.get_type_module(type_atom),
         {:ok, validated} <- type_module.validate(value) do
      {:ok, validated}
    else
      error -> error
    end
  end

  defp reconstruct_value(:tensor, metadata, data) do
    %{
      shape: Map.get(metadata, "shape", []),
      data: data
    }
  end

  defp reconstruct_value(:embedding, _metadata, data) do
    data
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
  defp parse_type("map"), do: {:ok, :map}     # Add this
  defp parse_type("list"), do: {:ok, :list}   # Add this
  defp parse_type(_), do: {:error, :unknown_type}
end
