defmodule Snakepit.Bridge.Variables.Types.Boolean do
  @moduledoc """
  Boolean type implementation for variables.

  The simplest type - just true or false with no constraints.
  """

  @behaviour Snakepit.Bridge.Variables.Types.Behaviour

  @impl true
  def validate(true), do: {:ok, true}
  def validate(false), do: {:ok, false}
  def validate("true"), do: {:ok, true}
  def validate("false"), do: {:ok, false}
  def validate(1), do: {:ok, true}
  def validate(0), do: {:ok, false}
  def validate(_), do: {:error, "must be a boolean (true or false)"}

  @impl true
  def validate_constraints(_value, _constraints) do
    # Booleans have no constraints
    :ok
  end

  @impl true
  def serialize(value) when is_boolean(value) do
    {:ok, Jason.encode!(value)}
  end

  def serialize(_), do: {:error, "cannot serialize non-boolean"}

  @impl true
  def deserialize(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, "true"} -> {:ok, true}
      {:ok, "false"} -> {:ok, false}
      {:ok, "1"} -> {:ok, true}
      {:ok, "0"} -> {:ok, false}
      {:ok, 1} -> {:ok, true}
      {:ok, 0} -> {:ok, false}
      _ -> {:error, "invalid boolean format"}
    end
  end

  def deserialize(_), do: {:error, "invalid boolean format"}
end
