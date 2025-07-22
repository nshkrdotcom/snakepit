defmodule Snakepit.Bridge.Variables.Types.Integer do
  @behaviour Snakepit.Bridge.Variables.Types.Behaviour

  @impl true
  def validate(value) when is_integer(value), do: {:ok, value}

  def validate(value) when is_float(value) do
    if Float.floor(value) == value do
      {:ok, trunc(value)}
    else
      {:error, "must be a whole number"}
    end
  end

  def validate(_), do: {:error, "must be an integer"}

  @impl true
  def validate_constraints(value, constraints) do
    min = Map.get(constraints, :min)
    max = Map.get(constraints, :max)

    cond do
      min && value < min -> {:error, "must be >= #{min}"}
      max && value > max -> {:error, "must be <= #{max}"}
      true -> :ok
    end
  end

  @impl true
  def serialize(value) do
    {:ok, Jason.encode!(value)}
  end

  @impl true
  def deserialize(json) do
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
end
