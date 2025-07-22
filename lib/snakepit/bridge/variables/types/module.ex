defmodule Snakepit.Bridge.Variables.Types.Module do
  @behaviour Snakepit.Bridge.Variables.Types.Behaviour

  @impl true
  def validate(value) when is_binary(value), do: {:ok, value}
  def validate(value) when is_atom(value), do: {:ok, to_string(value)}
  def validate(_), do: {:error, "must be a module name"}

  @impl true
  def validate_constraints(value, constraints) do
    allowed_modules = Map.get(constraints, :allowed_modules, [])

    if allowed_modules == [] or value in allowed_modules do
      :ok
    else
      {:error, "must be one of the allowed modules: #{Enum.join(allowed_modules, ", ")}"}
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
      _ -> {:error, "invalid module format"}
    end
  end
end
