defmodule Snakepit.Bridge.Variables do
  @moduledoc """
  Main entry point for variable-related functionality.

  This module provides convenience functions and acts as the
  public API for variable operations.
  """

  alias Snakepit.Bridge.Variables.{Variable, Types}

  @doc """
  Lists all supported variable types.
  """
  @spec supported_types() :: [atom()]
  def supported_types do
    Types.list_types()
  end

  @doc """
  Validates a value against a type and constraints.
  """
  @spec validate(any(), atom(), map()) :: {:ok, any()} | {:error, String.t()}
  def validate(value, type, constraints \\ %{}) do
    with {:ok, type_module} <- Types.get_type_module(type),
         {:ok, validated} <- type_module.validate(value),
         :ok <- type_module.validate_constraints(validated, constraints) do
      {:ok, validated}
    end
  end

  @doc """
  Creates a properly typed variable.
  """
  @spec create_variable(map()) :: {:ok, Variable.t()} | {:error, term()}
  def create_variable(attrs) do
    with {:ok, type_module} <- Types.get_type_module(attrs.type),
         {:ok, validated_value} <- type_module.validate(attrs.value),
         constraints = Map.get(attrs, :constraints, %{}),
         :ok <- type_module.validate_constraints(validated_value, constraints) do
      variable = Variable.new(Map.put(attrs, :value, validated_value))
      {:ok, variable}
    end
  end
end
