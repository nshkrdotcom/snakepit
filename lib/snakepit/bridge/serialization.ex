defmodule Snakepit.Bridge.Serialization do
  @moduledoc """
  Centralized serialization for the bridge protocol.
  """

  alias Snakepit.Bridge.Variables.Types

  @doc """
  Encode a value to protobuf Any with JSON payload.
  """
  def encode_any(value, type) do
    with {:ok, type_module} <- Types.get_type_module(type),
         {:ok, normalized} <- type_module.validate(value),
         {:ok, json} <- type_module.serialize(normalized) do
      any = %{
        type_url: "type.googleapis.com/snakepit.#{type}",
        value: json
      }

      {:ok, any}
    end
  end

  @doc """
  Decode a protobuf Any to a typed value.
  """
  def decode_any(%{type_url: type_url, value: json_value} = _any) do
    # Extract type from URL
    type = extract_type_from_url(type_url)

    with {:ok, type_atom} <- parse_type(type),
         {:ok, type_module} <- Types.get_type_module(type_atom),
         {:ok, value} <- type_module.deserialize(json_value) do
      {:ok, value}
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
