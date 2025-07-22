defmodule Snakepit.Bridge.Variables.Types.Tensor do
  @behaviour Snakepit.Bridge.Variables.Types.Behaviour

  @impl true
  def validate(%{"shape" => shape, "data" => data} = value)
      when is_list(shape) and is_list(data) do
    expected_size = Enum.reduce(shape, 1, &(&1 * &2))
    actual_size = length(List.flatten(data))

    if expected_size == actual_size do
      {:ok, value}
    else
      {:error, "data size doesn't match shape"}
    end
  end

  def validate(_), do: {:error, "must be a tensor with shape and data"}

  @impl true
  def validate_constraints(value, constraints) do
    expected_shape = Map.get(constraints, :shape)

    if expected_shape && value["shape"] != expected_shape do
      {:error, "shape must be #{inspect(expected_shape)}"}
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
      {:ok, %{"shape" => _shape, "data" => _data}} = result ->
        result

      _ ->
        {:error, "invalid tensor format"}
    end
  end
end
