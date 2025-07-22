defmodule Snakepit.Bridge.SerializationTest do
  use ExUnit.Case, async: true

  alias Snakepit.Bridge.Serialization

  describe "basic type serialization" do
    test "float serialization round-trip" do
      value = 3.14
      {:ok, any} = Serialization.encode_any(value, :float)
      {:ok, decoded} = Serialization.decode_any(any)
      assert decoded == value
    end

    test "integer serialization round-trip" do
      value = 42
      {:ok, any} = Serialization.encode_any(value, :integer)
      {:ok, decoded} = Serialization.decode_any(any)
      assert decoded == value
    end

    test "string serialization round-trip" do
      value = "hello world"
      {:ok, any} = Serialization.encode_any(value, :string)
      {:ok, decoded} = Serialization.decode_any(any)
      assert decoded == value
    end

    test "boolean serialization round-trip" do
      for value <- [true, false] do
        {:ok, any} = Serialization.encode_any(value, :boolean)
        {:ok, decoded} = Serialization.decode_any(any)
        assert decoded == value
      end
    end
  end

  describe "special float values" do
    test "infinity values" do
      for value <- [:infinity, :negative_infinity] do
        {:ok, any} = Serialization.encode_any(value, :float)
        {:ok, decoded} = Serialization.decode_any(any)
        assert decoded == value
      end
    end

    test "NaN value" do
      {:ok, any} = Serialization.encode_any(:nan, :float)
      {:ok, decoded} = Serialization.decode_any(any)
      assert decoded == :nan
    end
  end

  describe "complex type serialization" do
    test "choice serialization" do
      value = "option_a"
      {:ok, any} = Serialization.encode_any(value, :choice)
      {:ok, decoded} = Serialization.decode_any(any)
      assert decoded == value
    end

    test "module serialization" do
      value = "ChainOfThought"
      {:ok, any} = Serialization.encode_any(value, :module)
      {:ok, decoded} = Serialization.decode_any(any)
      assert decoded == value
    end

    test "embedding serialization" do
      value = [0.1, 0.2, 0.3, 0.4]
      {:ok, any} = Serialization.encode_any(value, :embedding)
      {:ok, decoded} = Serialization.decode_any(any)
      assert decoded == value
    end

    test "tensor serialization" do
      value = %{"shape" => [2, 3], "data" => [1, 2, 3, 4, 5, 6]}
      {:ok, any} = Serialization.encode_any(value, :tensor)
      {:ok, decoded} = Serialization.decode_any(any)
      assert decoded == value
    end
  end

  describe "constraint validation" do
    test "numeric constraints" do
      constraints = %{min: 0, max: 1}
      assert :ok = Serialization.validate_constraints(0.5, :float, constraints)
      assert {:error, _} = Serialization.validate_constraints(1.5, :float, constraints)
      assert {:error, _} = Serialization.validate_constraints(-0.5, :float, constraints)
    end

    test "string constraints" do
      constraints = %{min_length: 3, max_length: 10}
      assert :ok = Serialization.validate_constraints("hello", :string, constraints)
      assert {:error, _} = Serialization.validate_constraints("hi", :string, constraints)

      assert {:error, _} =
               Serialization.validate_constraints("this is too long", :string, constraints)
    end

    test "choice constraints" do
      constraints = %{choices: ["a", "b", "c"]}
      assert :ok = Serialization.validate_constraints("a", :choice, constraints)
      assert {:error, _} = Serialization.validate_constraints("d", :choice, constraints)
    end

    test "embedding dimension constraints" do
      constraints = %{dimensions: 4}
      assert :ok = Serialization.validate_constraints([1, 2, 3, 4], :embedding, constraints)
      assert {:error, _} = Serialization.validate_constraints([1, 2, 3], :embedding, constraints)
    end
  end

  describe "type validation" do
    test "float accepts integers" do
      {:ok, any} = Serialization.encode_any(42, :float)
      {:ok, decoded} = Serialization.decode_any(any)
      assert decoded == 42.0
    end

    test "integer rejects floats with decimals" do
      assert {:error, _} = Serialization.encode_any(3.14, :integer)
    end

    test "integer accepts whole number floats" do
      {:ok, any} = Serialization.encode_any(42.0, :integer)
      {:ok, decoded} = Serialization.decode_any(any)
      assert decoded == 42
    end

    test "embedding normalizes to floats" do
      {:ok, any} = Serialization.encode_any([1, 2, 3], :embedding)
      {:ok, decoded} = Serialization.decode_any(any)
      assert decoded == [1.0, 2.0, 3.0]
    end
  end

  describe "error handling" do
    test "invalid type" do
      assert {:error, {:unknown_type, :invalid_type}} =
               Serialization.encode_any("value", :invalid_type)
    end

    test "type mismatch" do
      assert {:error, _} = Serialization.encode_any("not a number", :float)
      assert {:error, _} = Serialization.encode_any(123, :boolean)
    end

    test "invalid tensor shape" do
      # Wrong data size
      value = %{"shape" => [2, 2], "data" => [1, 2, 3]}
      assert {:error, _} = Serialization.encode_any(value, :tensor)
    end
  end
end
