defmodule Snakepit.Bridge.Variables.Types.Float do
  @behaviour Snakepit.Bridge.Variables.Types.Behaviour
  
  @impl true
  def validate(value) when is_float(value), do: {:ok, value}
  def validate(value) when is_integer(value), do: {:ok, value * 1.0}
  def validate(_), do: {:error, "must be a number"}
  
  @impl true
  def validate_constraints(value, constraints) do
    min = Map.get(constraints, :min, :negative_infinity)
    max = Map.get(constraints, :max, :infinity)
    
    cond do
      min != :negative_infinity and value < min ->
        {:error, "must be >= #{min}"}
      max != :infinity and value > max ->
        {:error, "must be <= #{max}"}
      true ->
        :ok
    end
  end
  
  @impl true
  def serialize(value) do
    # Handle special float values
    json_value = cond do
      is_nan(value) -> "NaN"
      value == :infinity -> "Infinity"
      value == :negative_infinity -> "-Infinity"
      true -> value
    end
    
    {:ok, Jason.encode!(json_value)}
  end
  
  @impl true
  def deserialize(json) do
    case Jason.decode(json) do
      {:ok, "NaN"} -> {:ok, :nan}
      {:ok, "Infinity"} -> {:ok, :infinity}
      {:ok, "-Infinity"} -> {:ok, :negative_infinity}
      {:ok, value} when is_number(value) -> {:ok, value * 1.0}
      _ -> {:error, "invalid float format"}
    end
  end
  
  defp is_nan(value) do
    # Elixir doesn't have NaN, but we support it for Python interop
    value == :nan
  end
end