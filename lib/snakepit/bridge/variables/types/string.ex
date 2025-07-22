defmodule Snakepit.Bridge.Variables.Types.String do
  @behaviour Snakepit.Bridge.Variables.Types.Behaviour

  @impl true
  def validate(value) when is_binary(value), do: {:ok, value}
  def validate(value) when is_atom(value), do: {:ok, to_string(value)}
  def validate(_), do: {:error, "must be a string"}

  @impl true
  def validate_constraints(value, constraints) do
    min_length = Map.get(constraints, :min_length, 0)
    max_length = Map.get(constraints, :max_length)
    pattern = Map.get(constraints, :pattern)

    length = String.length(value)

    cond do
      length < min_length ->
        {:error, "must be at least #{min_length} characters"}

      max_length && length > max_length ->
        {:error, "must be at most #{max_length} characters"}

      pattern && not Regex.match?(~r/#{pattern}/, value) ->
        {:error, "must match pattern: #{pattern}"}

      true ->
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
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> {:error, "invalid string format"}
    end
  end
end
