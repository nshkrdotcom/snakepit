defmodule Snakepit.ErrorTest do
  use ExUnit.Case, async: true

  alias Snakepit.Error

  describe "Error struct" do
    test "has required fields" do
      error = %Error{
        category: :worker,
        message: "Worker not found",
        details: %{worker_id: "worker_1"}
      }

      assert error.category == :worker
      assert error.message == "Worker not found"
      assert error.details == %{worker_id: "worker_1"}
      assert error.python_traceback == nil
      assert error.grpc_status == nil
    end

    test "validates category field" do
      # Valid categories
      valid_categories = [:worker, :timeout, :python_error, :grpc_error, :validation, :pool]

      for category <- valid_categories do
        error = %Error{category: category, message: "test", details: %{}}
        assert error.category == category
      end
    end

    test "enforces required fields at struct construction time" do
      assert_raise ArgumentError, fn ->
        struct!(Error, category: :worker, message: "missing details")
      end
    end
  end

  describe "worker_error/2" do
    test "creates worker error with default details" do
      error = Error.worker_error("Worker crashed")

      assert error.category == :worker
      assert error.message == "Worker crashed"
      assert error.details == %{}
    end

    test "creates worker error with custom details" do
      error = Error.worker_error("Worker not found", %{worker_id: "w1", pool: :default})

      assert error.category == :worker
      assert error.message == "Worker not found"
      assert error.details == %{worker_id: "w1", pool: :default}
    end
  end

  describe "timeout_error/2" do
    test "creates timeout error" do
      error = Error.timeout_error("Request timed out", %{timeout_ms: 5000})

      assert error.category == :timeout
      assert error.message == "Request timed out"
      assert error.details.timeout_ms == 5000
    end
  end

  describe "python_error/4" do
    test "creates Python exception error with traceback" do
      traceback = """
      Traceback (most recent call last):
        File "script.py", line 10, in <module>
          do_something()
        File "script.py", line 5, in do_something
          raise ValueError("Invalid input")
      ValueError: Invalid input
      """

      error =
        Error.python_error("ValueError", "Invalid input", traceback, %{function: "do_something"})

      assert error.category == :python_error
      assert error.message == "ValueError: Invalid input"
      assert error.python_traceback == traceback
      assert error.details.exception_type == "ValueError"
      assert error.details.function == "do_something"
    end
  end

  describe "grpc_error/3" do
    test "creates gRPC error with status" do
      error = Error.grpc_error(:unavailable, "Service unavailable", %{retry_after: 5})

      assert error.category == :grpc_error
      assert error.message == "Service unavailable"
      assert error.grpc_status == :unavailable
      assert error.details.retry_after == 5
    end
  end

  describe "pool_error/2" do
    test "creates pool error" do
      error = Error.pool_error("Pool not found", %{pool_name: :test_pool})

      assert error.category == :pool
      assert error.message == "Pool not found"
      assert error.details.pool_name == :test_pool
    end
  end

  describe "validation_error/2" do
    test "creates validation error" do
      error =
        Error.validation_error("Invalid parameters", %{
          field: "user_id",
          expected: "integer",
          got: "string"
        })

      assert error.category == :validation
      assert error.message == "Invalid parameters"
      assert error.details.field == "user_id"
    end
  end

  describe "String.Chars implementation" do
    test "converts error to readable string" do
      error = Error.worker_error("Worker not found", %{worker_id: "w1"})
      string = to_string(error)

      assert string =~ "Worker not found"
      assert string =~ "worker_id"
      assert string =~ "w1"
    end

    test "includes traceback if present" do
      error = Error.python_error("ValueError", "Bad value", "Traceback line 1\nTraceback line 2")
      string = to_string(error)

      assert string =~ "ValueError: Bad value"
      assert string =~ "Traceback"
    end
  end

  describe "backward compatibility" do
    test "pattern matching works with old and new formats" do
      # Old format
      old_result = {:error, :worker_not_found}

      case old_result do
        {:error, :worker_not_found} -> assert true
        _ -> flunk("Pattern match failed")
      end

      # New format
      new_result = {:error, Error.worker_error("Worker not found")}

      case new_result do
        {:error, %Error{category: :worker}} -> assert true
        _ -> flunk("Pattern match failed")
      end
    end
  end

  describe "normalize_public_result/2" do
    test "normalizes bare pool_not_found reason with metadata" do
      assert {:error, %Error{category: :pool, details: details}} =
               Error.normalize_public_result({:error, :pool_not_found}, %{pool_name: :alpha})

      assert details.reason == :pool_not_found
      assert details.pool_name == :alpha
    end

    test "normalizes tuple pool_not_found reason and preserves pool name" do
      assert {:error, %Error{category: :pool, details: details}} =
               Error.normalize_public_result(
                 {:error, {:pool_not_found, :alpha}},
                 %{command: "ping"}
               )

      assert details.reason == :pool_not_found
      assert details.pool_name == :alpha
      assert details.command == "ping"
    end
  end
end
