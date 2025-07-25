defmodule Snakepit.Bridge.Variables.TypesTest do
  use ExUnit.Case, async: true

  alias Snakepit.Bridge.Variables.Types

  describe "type registry" do
    test "get_type_module/1" do
      assert {:ok, Types.Float} = Types.get_type_module(:float)
      assert {:ok, Types.Integer} = Types.get_type_module(:integer)
      assert {:ok, Types.String} = Types.get_type_module(:string)
      assert {:ok, Types.Boolean} = Types.get_type_module(:boolean)

      # String type names
      assert {:ok, Types.Float} = Types.get_type_module("float")

      # Unknown type
      assert {:error, {:unknown_type, :unknown}} = Types.get_type_module(:unknown)
    end

    test "list_types/0" do
      types = Types.list_types()
      assert :float in types
      assert :integer in types
      assert :string in types
      assert :boolean in types
    end
  end

  describe "float type" do
    test "validation" do
      assert {:ok, 3.14} = Types.validate_value(3.14, :float)
      assert {:ok, 42.0} = Types.validate_value(42, :float)
      assert {:ok, :infinity} = Types.validate_value(:infinity, :float)
      assert {:ok, :nan} = Types.validate_value(:nan, :float)

      assert {:error, _} = Types.validate_value("not a number", :float)
    end

    test "constraints" do
      constraints = %{min: 0.0, max: 1.0}
      assert {:ok, 0.5} = Types.validate_value(0.5, :float, constraints)
      assert {:error, msg} = Types.validate_value(-0.5, :float, constraints)
      assert msg =~ "below minimum"
      assert {:error, msg} = Types.validate_value(1.5, :float, constraints)
      assert msg =~ "above maximum"
    end

    test "serialization" do
      alias Snakepit.Bridge.Serialization

      # Test encoding
      assert {:ok, any, _binary_data} = Serialization.encode_any(3.14, :float)
      assert any.type_url == "type.googleapis.com/snakepit.float"
      assert Jason.decode!(any.value) == 3.14

      assert {:ok, any, _binary_data} = Serialization.encode_any(:infinity, :float)
      assert Jason.decode!(any.value) == "Infinity"

      assert {:ok, any, _binary_data} = Serialization.encode_any(:negative_infinity, :float)
      assert Jason.decode!(any.value) == "-Infinity"

      assert {:ok, any, _binary_data} = Serialization.encode_any(:nan, :float)
      assert Jason.decode!(any.value) == "NaN"

      # Test decoding
      assert {:ok, 3.14} =
               Serialization.decode_any(%{
                 type_url: "type.googleapis.com/snakepit.float",
                 value: "3.14"
               })

      assert {:ok, :infinity} =
               Serialization.decode_any(%{
                 type_url: "type.googleapis.com/snakepit.float",
                 value: "\"Infinity\""
               })

      assert {:ok, :negative_infinity} =
               Serialization.decode_any(%{
                 type_url: "type.googleapis.com/snakepit.float",
                 value: "\"-Infinity\""
               })

      assert {:ok, :nan} =
               Serialization.decode_any(%{
                 type_url: "type.googleapis.com/snakepit.float",
                 value: "\"NaN\""
               })
    end
  end

  describe "integer type" do
    test "validation" do
      assert {:ok, 42} = Types.validate_value(42, :integer)
      assert {:ok, -100} = Types.validate_value(-100, :integer)
      assert {:ok, 0} = Types.validate_value(0, :integer)

      # Whole number floats accepted
      assert {:ok, 42} = Types.validate_value(42.0, :integer)

      # Non-whole floats rejected
      assert {:error, _} = Types.validate_value(3.14, :integer)
      assert {:error, _} = Types.validate_value("42", :integer)
    end

    test "constraints" do
      constraints = %{min: 0, max: 100}
      assert {:ok, 50} = Types.validate_value(50, :integer, constraints)
      assert {:error, _} = Types.validate_value(-1, :integer, constraints)
      assert {:error, _} = Types.validate_value(101, :integer, constraints)
    end

    test "serialization" do
      alias Snakepit.Bridge.Serialization

      # Test encoding
      assert {:ok, any, _binary_data} = Serialization.encode_any(42, :integer)
      assert any.type_url == "type.googleapis.com/snakepit.integer"
      assert Jason.decode!(any.value) == 42

      assert {:ok, any, _binary_data} = Serialization.encode_any(-100, :integer)
      assert Jason.decode!(any.value) == -100

      assert {:ok, any, _binary_data} = Serialization.encode_any(0, :integer)
      assert Jason.decode!(any.value) == 0

      # Test decoding
      assert {:ok, 42} =
               Serialization.decode_any(%{
                 type_url: "type.googleapis.com/snakepit.integer",
                 value: "42"
               })

      assert {:ok, -100} =
               Serialization.decode_any(%{
                 type_url: "type.googleapis.com/snakepit.integer",
                 value: "-100"
               })
    end
  end

  describe "string type" do
    test "validation" do
      assert {:ok, "hello"} = Types.validate_value("hello", :string)
      assert {:ok, ""} = Types.validate_value("", :string)
      assert {:ok, "test"} = Types.validate_value(:test, :string)

      assert {:error, _} = Types.validate_value(nil, :string)
      assert {:error, _} = Types.validate_value(123, :string)
    end

    test "length constraints" do
      constraints = %{min_length: 3, max_length: 10}
      assert {:ok, "hello"} = Types.validate_value("hello", :string, constraints)
      assert {:error, msg} = Types.validate_value("hi", :string, constraints)
      assert msg =~ "at least 3 characters"
      assert {:error, msg} = Types.validate_value("this is too long", :string, constraints)
      assert msg =~ "at most 10 characters"
    end

    test "pattern constraint" do
      constraints = %{pattern: "^[A-Z][a-z]+$"}
      assert {:ok, "Hello"} = Types.validate_value("Hello", :string, constraints)
      assert {:error, _} = Types.validate_value("hello", :string, constraints)
      assert {:error, _} = Types.validate_value("HELLO", :string, constraints)
    end

    test "enum constraint" do
      constraints = %{enum: ["red", "green", "blue"]}
      assert {:ok, "red"} = Types.validate_value("red", :string, constraints)
      assert {:error, msg} = Types.validate_value("yellow", :string, constraints)
      assert msg =~ "must be one of: red, green, blue"
    end
  end

  describe "boolean type" do
    test "validation" do
      assert {:ok, true} = Types.validate_value(true, :boolean)
      assert {:ok, false} = Types.validate_value(false, :boolean)
      assert {:ok, true} = Types.validate_value("true", :boolean)
      assert {:ok, false} = Types.validate_value("false", :boolean)
      assert {:ok, true} = Types.validate_value(1, :boolean)
      assert {:ok, false} = Types.validate_value(0, :boolean)

      assert {:error, _} = Types.validate_value("yes", :boolean)
      assert {:error, _} = Types.validate_value(nil, :boolean)
    end

    test "serialization" do
      alias Snakepit.Bridge.Serialization

      # Test encoding
      assert {:ok, any, _binary_data} = Serialization.encode_any(true, :boolean)
      assert any.type_url == "type.googleapis.com/snakepit.boolean"
      assert Jason.decode!(any.value) == true

      assert {:ok, any, _binary_data} = Serialization.encode_any(false, :boolean)
      assert Jason.decode!(any.value) == false

      # Test decoding
      assert {:ok, true} =
               Serialization.decode_any(%{
                 type_url: "type.googleapis.com/snakepit.boolean",
                 value: "true"
               })

      assert {:ok, false} =
               Serialization.decode_any(%{
                 type_url: "type.googleapis.com/snakepit.boolean",
                 value: "false"
               })
    end
  end

  describe "cross-type validation" do
    test "valid?/3 helper" do
      assert Types.valid?(3.14, :float)
      assert Types.valid?(42, :integer)
      assert Types.valid?("hello", :string)
      assert Types.valid?(true, :boolean)

      refute Types.valid?("not a number", :float)
      refute Types.valid?(3.14, :integer)
      refute Types.valid?(nil, :string)
      refute Types.valid?("yes", :boolean)
    end
  end
end
