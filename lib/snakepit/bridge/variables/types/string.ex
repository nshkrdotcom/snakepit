defmodule Snakepit.Bridge.Variables.Types.String do
  @moduledoc """
  String type implementation for variables.

  Supports:
  - Automatic atom to string conversion
  - Length constraints (min_length, max_length)
  - Pattern matching with regex
  - Enumeration constraint (allowed values)
  """

  @behaviour Snakepit.Bridge.Variables.Types.Behaviour

  @impl true
  def validate(value) when is_binary(value), do: {:ok, value}

  def validate(value) when is_atom(value) and not is_nil(value) do
    {:ok, to_string(value)}
  end

  def validate(nil), do: {:error, "cannot be nil"}
  def validate(_), do: {:error, "must be a string"}

  @impl true
  def validate_constraints(value, constraints) do
    length = String.length(value)

    cond do
      min_length = Map.get(constraints, :min_length) ->
        if length >= min_length do
          validate_constraints(value, Map.delete(constraints, :min_length))
        else
          {:error, "must be at least #{min_length} characters, got #{length}"}
        end

      max_length = Map.get(constraints, :max_length) ->
        if length <= max_length do
          validate_constraints(value, Map.delete(constraints, :max_length))
        else
          {:error, "must be at most #{max_length} characters, got #{length}"}
        end

      pattern = Map.get(constraints, :pattern) ->
        regex = compile_pattern(pattern)

        if Regex.match?(regex, value) do
          validate_constraints(value, Map.delete(constraints, :pattern))
        else
          {:error, "must match pattern: #{pattern}"}
        end

      enum = Map.get(constraints, :enum) ->
        if value in enum do
          validate_constraints(value, Map.delete(constraints, :enum))
        else
          {:error, "must be one of: #{Enum.join(enum, ", ")}"}
        end

      true ->
        :ok
    end
  end

  @impl true
  def serialize(value) when is_binary(value) do
    # Encode as JSON for compatibility with gRPC layer
    {:ok, Jason.encode!(value)}
  end

  def serialize(_), do: {:error, "cannot serialize non-string"}

  @impl true
  def deserialize(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> {:error, "invalid string format"}
    end
  end

  def deserialize(_), do: {:error, "invalid string format"}

  defp compile_pattern(pattern) when is_binary(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} ->
        regex

      {:error, _} ->
        # If pattern compilation fails, create a literal match regex
        Regex.compile!(Regex.escape(pattern))
    end
  end

  defp compile_pattern(%Regex{} = regex), do: regex
end
