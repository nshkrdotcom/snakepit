defmodule Snakepit.Bridge.Variables.Types.Embedding do
  @behaviour Snakepit.Bridge.Variables.Types.Behaviour

  @impl true
  def validate(value) when is_list(value) do
    if Enum.all?(value, &is_number/1) do
      # Normalize to floats
      {:ok, Enum.map(value, &(&1 * 1.0))}
    else
      {:error, "must be a list of numbers"}
    end
  end

  def validate(_), do: {:error, "must be a numeric list"}

  @impl true
  def validate_constraints(value, constraints) do
    dimensions = Map.get(constraints, :dimensions)

    if dimensions && length(value) != dimensions do
      {:error, "must have exactly #{dimensions} dimensions"}
    else
      :ok
    end
  end

  @impl true
  def serialize(value) do
    {:ok, Jason.encode!(value)}
  end

  @impl true
  def deserialize(json) do
    case Jason.decode(json) do
      {:ok, value} when is_list(value) ->
        if Enum.all?(value, &is_number/1) do
          {:ok, Enum.map(value, &(&1 * 1.0))}
        else
          {:error, "invalid embedding format"}
        end

      _ ->
        {:error, "invalid embedding format"}
    end
  end
end
