defmodule Snakepit.Bridge.Variables.Types.Float do
  @moduledoc """
  Float type implementation for variables.

  Supports:
  - Automatic integer to float conversion
  - Min/max constraints
  - Special values (infinity, NaN) for Python compatibility
  """

  @behaviour Snakepit.Bridge.Variables.Types.Behaviour

  @impl true
  def validate(value) when is_float(value), do: {:ok, value}
  def validate(value) when is_integer(value), do: {:ok, value * 1.0}
  def validate(:infinity), do: {:ok, :infinity}
  def validate(:negative_infinity), do: {:ok, :negative_infinity}
  def validate(:nan), do: {:ok, :nan}
  def validate("Infinity"), do: {:ok, :infinity}
  def validate("-Infinity"), do: {:ok, :negative_infinity}
  def validate("NaN"), do: {:ok, :nan}
  def validate(_), do: {:error, "must be a number"}

  @impl true
  def validate_constraints(value, constraints) do
    cond do
      # Special values bypass normal constraints
      value in [:infinity, :negative_infinity, :nan] ->
        :ok

      # Check min constraint
      min = Map.get(constraints, :min) ->
        if value >= min do
          validate_constraints(value, Map.delete(constraints, :min))
        else
          {:error, "value #{value} is below minimum #{min}"}
        end

      # Check max constraint  
      max = Map.get(constraints, :max) ->
        if value <= max do
          validate_constraints(value, Map.delete(constraints, :max))
        else
          {:error, "value #{value} is above maximum #{max}"}
        end

      # No more constraints
      true ->
        :ok
    end
  end

  @impl true
  def serialize(value) do
    # Delegate to centralized Serialization module
    Snakepit.Bridge.Serialization.encode_any(value, :float)
  end

  @impl true
  def deserialize(json) when is_binary(json) do
    with {:ok, value} <- Jason.decode(json),
         {:ok, validated} <- validate(value) do
      {:ok, validated}
    else
      {:error, %Jason.DecodeError{} = e} ->
        {:error, "JSON decoding failed: #{Exception.message(e)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def deserialize(_), do: {:error, "invalid float format"}
end
