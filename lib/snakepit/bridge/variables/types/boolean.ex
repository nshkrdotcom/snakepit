defmodule Snakepit.Bridge.Variables.Types.Boolean do
  @behaviour Snakepit.Bridge.Variables.Types.Behaviour
  
  @impl true
  def validate(value) when is_boolean(value), do: {:ok, value}
  def validate(_), do: {:error, "must be a boolean"}
  
  @impl true
  def validate_constraints(_value, _constraints), do: :ok
  
  @impl true
  def serialize(value) do
    {:ok, Jason.encode!(value)}
  end
  
  @impl true
  def deserialize(json) do
    case Jason.decode(json) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      _ -> {:error, "invalid boolean format"}
    end
  end
end