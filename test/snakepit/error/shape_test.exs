defmodule Snakepit.Error.ShapeTest do
  use ExUnit.Case, async: true

  alias Snakepit.Error.Shape

  describe "shape_mismatch/3" do
    test "creates shape mismatch error with dimensions" do
      error = Shape.shape_mismatch([3, 224, 224], [3, 256, 256], "conv2d")

      assert %Snakepit.Error.ShapeMismatch{} = error
      assert error.expected == [3, 224, 224]
      assert error.got == [3, 256, 256]
      assert error.operation == "conv2d"
    end

    test "includes dimension info when shapes differ at specific index" do
      error = Shape.shape_mismatch([10, 20, 30], [10, 25, 30], "matmul")

      assert error.dimension == 1
      assert error.expected_dim == 20
      assert error.got_dim == 25
    end

    test "handles rank mismatch" do
      error = Shape.shape_mismatch([10, 20], [10, 20, 30], "add")

      assert error.dimension == nil
      assert error.message =~ "rank"
    end
  end

  describe "dimension_mismatch/4" do
    test "creates dimension-specific error" do
      error = Shape.dimension_mismatch(1, 128, 256, "linear")

      assert %Snakepit.Error.ShapeMismatch{} = error
      assert error.dimension == 1
      assert error.expected_dim == 128
      assert error.got_dim == 256
      assert error.operation == "linear"
    end
  end

  describe "broadcast_error/3" do
    test "creates broadcast error" do
      error = Shape.broadcast_error([3, 1], [4], "add")

      assert %Snakepit.Error.ShapeMismatch{} = error
      assert error.message =~ "broadcast"
    end
  end

  describe "Exception protocol" do
    test "ShapeMismatch implements Exception" do
      error = Shape.shape_mismatch([10, 20], [10, 30], "matmul")

      message = Exception.message(error)

      assert is_binary(message)
      assert message =~ "shape mismatch" or message =~ "Shape mismatch"
      assert message =~ "matmul"
    end
  end

  describe "telemetry emission" do
    test "emits telemetry event on creation" do
      parent = self()
      ref = make_ref()

      :telemetry.attach(
        "shape-test-#{inspect(ref)}",
        [:snakepit, :error, :shape_mismatch],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:telemetry, metadata})
        end,
        nil
      )

      _error = Shape.shape_mismatch([1, 2], [3, 4], "test_op")

      assert_receive {:telemetry, metadata}
      assert metadata.expected == [1, 2]
      assert metadata.got == [3, 4]
      assert metadata.operation == "test_op"

      :telemetry.detach("shape-test-#{inspect(ref)}")
    end
  end
end
