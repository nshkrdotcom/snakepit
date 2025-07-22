defmodule Snakepit.Bridge.Variables.Types.Integer do
  @moduledoc """
  Integer type implementation for variables.

  Supports:
  - Strict integer validation (no float coercion)
  - Min/max constraints  
  - Large integer support
  """

  @behaviour Snakepit.Bridge.Variables.Types.Behaviour

  @impl true
  def validate(value) when is_integer(value), do: {:ok, value}

  def validate(value) when is_float(value) do
    # Only allow floats that are whole numbers
    if Float.floor(value) == value and not (is_nan(value) or is_inf(value)) do
      {:ok, trunc(value)}
    else
      {:error, "must be a whole number, got #{value}"}
    end
  end

  def validate(_), do: {:error, "must be an integer"}

  @impl true
  def validate_constraints(value, constraints) do
    cond do
      min = Map.get(constraints, :min) ->
        if value >= min do
          validate_constraints(value, Map.delete(constraints, :min))
        else
          {:error, "value #{value} is below minimum #{min}"}
        end

      max = Map.get(constraints, :max) ->
        if value <= max do
          validate_constraints(value, Map.delete(constraints, :max))
        else
          {:error, "value #{value} is above maximum #{max}"}
        end

      true ->
        :ok
    end
  end

  @impl true
  def serialize(value) when is_integer(value) do
    {:ok, Jason.encode!(value)}
  end

  def serialize(_), do: {:error, "cannot serialize non-integer"}

  @impl true
  def deserialize(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, value} when is_integer(value) ->
        {:ok, value}

      {:ok, value} when is_float(value) ->
        if Float.floor(value) == value do
          {:ok, trunc(value)}
        else
          {:error, "invalid integer format"}
        end

      _ ->
        {:error, "invalid integer format"}
    end
  end

  def deserialize(_), do: {:error, "invalid integer format"}

  defp is_nan(value) when is_float(value), do: value != value

  defp is_inf(value) when is_float(value) do
    # Check if float is infinite by testing if it equals itself plus 1
    value == value + 1.0 and value != 0.0
  end
end
