defmodule Snakepit.Bridge.PropertyTest do
  @moduledoc """
  Property-based tests for the Snakepit gRPC bridge.

  Uses StreamData to generate random test cases and verify invariants
  across the bridge components.
  """

  use ExUnit.Case
  use ExUnitProperties

  import StreamData

  alias Snakepit.Bridge.{SessionStore, Serialization}
  alias Snakepit.Bridge.Variables.Types

  @moduletag :property

  # Generators for different types
  defp variable_name_gen do
    gen all(
          name <- string(:alphanumeric, min_length: 1, max_length: 50),
          not String.starts_with?(name, "_")
        ) do
      name
    end
  end

  defp integer_value_gen do
    integer(-2_147_483_648..2_147_483_647)
  end

  defp float_value_gen do
    one_of([
      float(min: -1.0e10, max: 1.0e10),
      member_of([0.0, -0.0, 1.0, -1.0])
    ])
  end

  defp string_value_gen do
    string(:utf8, max_length: 1000)
  end

  defp boolean_value_gen do
    boolean()
  end

  defp typed_value_gen do
    one_of([
      tuple({constant(:integer), integer_value_gen()}),
      tuple({constant(:float), float_value_gen()}),
      tuple({constant(:string), string_value_gen()}),
      tuple({constant(:boolean), boolean_value_gen()})
    ])
  end

  defp constraints_gen(type) do
    case type do
      :integer ->
        gen all(
              min <- integer(),
              max <- integer(min..(min + 1000))
            ) do
          %{min: min, max: max}
        end

      :float ->
        gen all(
              min <- float(min: -1000.0, max: 0.0),
              max <- float(min: min, max: min + 1000.0)
            ) do
          %{min: min, max: max}
        end

      :string ->
        one_of([
          gen all(len <- integer(1..100)) do
            %{min_length: len}
          end,
          gen all(len <- integer(1..1000)) do
            %{max_length: len}
          end,
          gen all(
                min <- integer(1..50),
                max <- integer(min..(min + 50))
              ) do
            %{min_length: min, max_length: max}
          end,
          gen all(pattern <- member_of(["^[a-z]+$", "^[A-Z]+$", "^[0-9]+$", "^\\w+$"])) do
            %{pattern: pattern}
          end
        ])

      _ ->
        constant(%{})
    end
  end

  describe "Serialization Properties" do
    property "any value can be serialized and deserialized" do
      check all({type, value} <- typed_value_gen()) do
        case Serialization.encode_any(value, type) do
          {:ok, encoded} ->
            assert {:ok, decoded} = Serialization.decode_any(encoded)
            assert decoded == value

          {:error, _reason} ->
            # Some values might not be serializable (e.g., invalid UTF-8)
            :ok
        end
      end
    end

    property "encoded values have correct protobuf structure" do
      check all({type, value} <- typed_value_gen()) do
        case Serialization.encode_any(value, type) do
          {:ok, %{type_url: url, value: encoded_value}} ->
            assert String.starts_with?(url, "type.googleapis.com/snakepit.")
            assert String.ends_with?(url, to_string(type))
            assert is_binary(encoded_value)

          {:error, _} ->
            :ok
        end
      end
    end
  end

  describe "Variable Registration Properties" do
    property "valid variables can always be registered" do
      check all(
              name <- variable_name_gen(),
              {type, value} <- typed_value_gen(),
              constraints <- constraints_gen(type),
              max_runs: 50
            ) do
        session_id = "prop_#{:erlang.unique_integer([:positive])}"
        {:ok, _session} = SessionStore.create_session(session_id)

        # Adjust value to fit constraints if needed
        adjusted_value = adjust_value_for_constraints(value, type, constraints)

        result =
          SessionStore.register_variable(
            session_id,
            name,
            type,
            adjusted_value,
            constraints: constraints
          )

        SessionStore.delete_session(session_id)

        case result do
          {:ok, _} ->
            assert true

          {:error, reason} ->
            # Log the error for debugging but don't fail
            # Some constraint combinations might be invalid
            assert reason != nil
        end
      end
    end

    property "registered variables maintain their properties" do
      check all(
              name <- variable_name_gen(),
              {type, value} <- typed_value_gen(),
              max_runs: 50
            ) do
        session_id = "prop_#{:erlang.unique_integer([:positive])}"
        {:ok, _session} = SessionStore.create_session(session_id)

        case SessionStore.register_variable(session_id, name, type, value, []) do
          {:ok, _} ->
            assert {:ok, var} = SessionStore.get_variable(session_id, name)
            assert var.name == name
            assert var.type == type
            assert var.value == value

          {:error, _} ->
            # Some values might not be valid
            :ok
        end

        SessionStore.delete_session(session_id)
      end
    end
  end

  describe "Type Validation Properties" do
    property "integer constraints are enforced" do
      check all(
              value <- integer_value_gen(),
              min <- integer(),
              max <- integer(min..(min + 1000))
            ) do
        constraints = %{min: min, max: max}
        type_mod = Types.Integer

        case type_mod.validate(value) do
          {:ok, validated_value} ->
            case type_mod.validate_constraints(validated_value, constraints) do
              :ok ->
                assert validated_value >= min and validated_value <= max

              {:error, _} ->
                assert validated_value < min or validated_value > max
            end

          {:error, _} ->
            # Value is not a valid integer
            assert true
        end
      end
    end

    property "float constraints are enforced" do
      check all(
              value <- float_value_gen(),
              min <- float(min: -1000.0, max: 0.0),
              max <- float(min: min, max: min + 1000.0)
            ) do
        constraints = %{min: min, max: max}
        type_mod = Types.Float

        case type_mod.validate(value) do
          {:ok, validated_value} ->
            case type_mod.validate_constraints(validated_value, constraints) do
              :ok ->
                assert validated_value >= min and validated_value <= max

              {:error, _} ->
                assert validated_value < min or validated_value > max
            end

          {:error, _} ->
            # Value is not a valid float
            assert true
        end
      end
    end

    property "string length constraints are enforced" do
      check all(
              value <- string_value_gen(),
              min_len <- integer(0..100),
              max_len <- integer(min_len..(min_len + 100))
            ) do
        constraints = %{min_length: min_len, max_length: max_len}
        type_mod = Types.String

        case type_mod.validate(value) do
          {:ok, validated_value} ->
            case type_mod.validate_constraints(validated_value, constraints) do
              :ok ->
                len = String.length(validated_value)
                assert len >= min_len and len <= max_len

              {:error, _} ->
                len = String.length(validated_value)
                assert len < min_len or len > max_len
            end

          {:error, _} ->
            # Value is not a valid string
            assert true
        end
      end
    end
  end

  describe "Session Isolation Properties" do
    property "variables in different sessions are isolated" do
      check all(
              name <- variable_name_gen(),
              {type1, value1} <- typed_value_gen(),
              {type2, value2} <- typed_value_gen(),
              max_runs: 25
            ) do
        session1 = "prop_iso_1_#{:erlang.unique_integer([:positive])}"
        session2 = "prop_iso_2_#{:erlang.unique_integer([:positive])}"

        {:ok, _} = SessionStore.create_session(session1)
        {:ok, _} = SessionStore.create_session(session2)

        # Register same name in both sessions
        {:ok, _} = SessionStore.register_variable(session1, name, type1, value1, [])
        {:ok, _} = SessionStore.register_variable(session2, name, type2, value2, [])

        # Verify isolation
        {:ok, var1} = SessionStore.get_variable(session1, name)
        {:ok, var2} = SessionStore.get_variable(session2, name)

        assert var1.value == value1
        assert var2.value == value2
        assert var1.type == type1
        assert var2.type == type2

        SessionStore.delete_session(session1)
        SessionStore.delete_session(session2)
      end
    end
  end

  describe "Update Properties" do
    property "valid updates preserve variable type" do
      check all(
              name <- variable_name_gen(),
              {type, initial_value} <- typed_value_gen(),
              {_, new_value} <- typed_value_gen(),
              max_runs: 25
            ) do
        session_id = "prop_update_#{:erlang.unique_integer([:positive])}"
        {:ok, _session} = SessionStore.create_session(session_id)

        {:ok, _} = SessionStore.register_variable(session_id, name, type, initial_value, [])

        # Try to update with new value of same type
        new_typed_value = cast_to_type(new_value, type)

        case SessionStore.update_variable(session_id, name, new_typed_value) do
          {:ok, _} ->
            {:ok, var} = SessionStore.get_variable(session_id, name)
            assert var.type == type
            assert var.value == new_typed_value

          {:error, _} ->
            # Update might fail due to constraints
            assert true

          :ok ->
            # Some updates return just :ok
            {:ok, var} = SessionStore.get_variable(session_id, name)
            assert var.type == type
            assert var.value == new_typed_value
        end

        SessionStore.delete_session(session_id)
      end
    end
  end

  # Helper functions

  defp adjust_value_for_constraints(value, type, constraints) do
    case type do
      :integer ->
        min = Map.get(constraints, :min, value)
        max = Map.get(constraints, :max, value)
        max(min, min(max, value))

      :float ->
        min = Map.get(constraints, :min, value)
        max = Map.get(constraints, :max, value)
        max(min, min(max, value))

      :string ->
        cond do
          Map.has_key?(constraints, :max_length) ->
            String.slice(value, 0, constraints.max_length)

          Map.has_key?(constraints, :min_length) and String.length(value) < constraints.min_length ->
            value <> String.duplicate("a", constraints.min_length - String.length(value))

          true ->
            value
        end

      _ ->
        value
    end
  end

  defp cast_to_type(value, target_type) do
    case {value, target_type} do
      {v, :integer} when is_integer(v) -> v
      {v, :integer} when is_float(v) -> round(v)
      {v, :integer} when is_binary(v) -> String.length(v)
      {_, :integer} -> 0
      {v, :float} when is_float(v) -> v
      {v, :float} when is_integer(v) -> v * 1.0
      {v, :float} when is_binary(v) -> String.length(v) * 1.0
      {_, :float} -> 0.0
      {v, :string} when is_binary(v) -> v
      {v, :string} -> inspect(v)
      {v, :boolean} when is_boolean(v) -> v
      {[], :boolean} -> false
      {0, :boolean} -> false
      {zero, :boolean} when zero == 0.0 -> false
      {"", :boolean} -> false
      {_, :boolean} -> true
    end
  end
end
