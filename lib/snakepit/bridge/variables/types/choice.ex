defmodule Snakepit.Bridge.Variables.Types.Choice do
  @behaviour Snakepit.Bridge.Variables.Types.Behaviour
  
  @impl true
  def validate(value) when is_binary(value), do: {:ok, value}
  def validate(value) when is_atom(value), do: {:ok, to_string(value)}
  def validate(_), do: {:error, "must be a string"}
  
  @impl true
  def validate_constraints(value, constraints) do
    choices = Map.get(constraints, :choices, [])
    
    if choices == [] or value in choices do
      :ok
    else
      {:error, "must be one of: #{Enum.join(choices, ", ")}"}
    end
  end
  
  @impl true
  def serialize(value) do
    {:ok, Jason.encode!(value)}
  end
  
  @impl true
  def deserialize(json) do
    case Jason.decode(json) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> {:error, "invalid choice format"}
    end
  end
end