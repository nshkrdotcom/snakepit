defmodule Snakepit.Error.ParserTest do
  use ExUnit.Case, async: true

  alias Snakepit.Error.Parser

  describe "parse/1" do
    test "parses Python ValueError" do
      error_data = %{
        "type" => "ValueError",
        "message" => "Invalid input",
        "traceback" => "Traceback..."
      }

      {:ok, error} = Parser.parse(error_data)

      assert %Snakepit.Error.ValueError{} = error
      assert error.message =~ "Invalid input"
    end

    test "parses Python TypeError" do
      error_data = %{
        "type" => "TypeError",
        "message" => "Expected int, got str"
      }

      {:ok, error} = Parser.parse(error_data)

      assert %Snakepit.Error.TypeError{} = error
    end

    test "parses shape mismatch from RuntimeError" do
      error_data = %{
        "type" => "RuntimeError",
        "message" => "shape mismatch: expected [3, 224, 224], got [3, 256, 256]",
        "traceback" => "..."
      }

      {:ok, error} = Parser.parse(error_data)

      assert %Snakepit.Error.ShapeMismatch{} = error
      assert error.expected == [3, 224, 224]
      assert error.got == [3, 256, 256]
    end

    test "parses CUDA OOM error" do
      error_data = %{
        "type" => "RuntimeError",
        "message" => "CUDA out of memory. Tried to allocate 2.00 GiB",
        "traceback" => "..."
      }

      {:ok, error} = Parser.parse(error_data)

      assert %Snakepit.Error.OutOfMemory{} = error
    end

    test "parses device mismatch error" do
      error_data = %{
        "type" => "RuntimeError",
        "message" =>
          "Expected all tensors to be on the same device, but found at least two devices, cuda:0 and cpu!"
      }

      {:ok, error} = Parser.parse(error_data)

      assert %Snakepit.Error.DeviceMismatch{} = error
    end

    test "returns generic PythonException for unknown errors" do
      error_data = %{
        "type" => "CustomError",
        "message" => "Something went wrong"
      }

      {:ok, error} = Parser.parse(error_data)

      assert %Snakepit.Error.PythonException{} = error
    end

    test "handles nil input" do
      assert {:error, :invalid_input} = Parser.parse(nil)
    end

    test "handles malformed input" do
      assert {:error, :invalid_input} = Parser.parse("not a map")
    end
  end

  describe "from_grpc_error/1" do
    test "parses gRPC error response" do
      grpc_error = %{
        status: :internal,
        message: "ValueError: Invalid argument"
      }

      {:ok, error} = Parser.from_grpc_error(grpc_error)

      assert is_struct(error)
    end

    test "handles gRPC error with structured payload" do
      grpc_error = %{
        status: :unknown,
        message: ~s({"type": "KeyError", "message": "key not found", "key": "foo"})
      }

      {:ok, error} = Parser.from_grpc_error(grpc_error)

      assert %Snakepit.Error.KeyError{} = error
    end
  end

  describe "extract_shape/1" do
    test "extracts shape from bracket notation" do
      shape = Parser.extract_shape("[3, 224, 224]")

      assert shape == [3, 224, 224]
    end

    test "extracts shape from tuple notation" do
      shape = Parser.extract_shape("(10, 20, 30)")

      assert shape == [10, 20, 30]
    end

    test "returns nil for invalid shape" do
      assert nil == Parser.extract_shape("not a shape")
    end
  end
end
