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
        type_url: "dspex.variables/#{type}",
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
  def parse_constraints(nil), do: %{}
  def parse_constraints(""), do: %{}
  def parse_constraints(json_string) when is_binary(json_string) do
    case Jason.decode(json_string) do
      {:ok, constraints} -> constraints
      {:error, _} -> %{}
    end
  end
  def parse_constraints(constraints) when is_map(constraints), do: constraints
  
  defp extract_type_from_url(type_url) do
    case String.split(type_url, "/") do
      [_prefix, type] -> type
      _ -> nil
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