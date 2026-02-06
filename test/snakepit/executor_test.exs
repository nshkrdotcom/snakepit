defmodule Snakepit.ExecutorTest do
  use ExUnit.Case, async: true

  alias Snakepit.Executor

  describe "execute/3" do
    test "executes function and returns result" do
      result = Executor.execute(fn -> {:ok, :success} end, [])
      assert result == {:ok, :success}
    end

    test "returns error result without retry" do
      result = Executor.execute(fn -> {:error, :failed} end, max_attempts: 1)
      assert result == {:error, :failed}
    end
  end

  describe "execute_with_retry/3" do
    test "succeeds on first try" do
      counter = :counters.new(1, [:atomics])

      result =
        Executor.execute_with_retry(
          fn ->
            :counters.add(counter, 1, 1)
            {:ok, :success}
          end,
          max_attempts: 3
        )

      assert result == {:ok, :success}
      assert :counters.get(counter, 1) == 1
    end

    test "retries on transient failure" do
      counter = :counters.new(1, [:atomics])

      result =
        Executor.execute_with_retry(
          fn ->
            count = :counters.get(counter, 1) + 1
            :counters.put(counter, 1, count)

            if count < 3 do
              {:error, :timeout}
            else
              {:ok, :success}
            end
          end,
          max_attempts: 5,
          backoff_ms: [10, 20, 30]
        )

      assert result == {:ok, :success}
      assert :counters.get(counter, 1) == 3
    end

    test "gives up after max attempts" do
      counter = :counters.new(1, [:atomics])

      result =
        Executor.execute_with_retry(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, :timeout}
          end,
          max_attempts: 3,
          backoff_ms: [10, 20]
        )

      assert {:error, :timeout} = result
      assert :counters.get(counter, 1) == 3
    end

    test "does not retry non-retriable errors" do
      counter = :counters.new(1, [:atomics])

      result =
        Executor.execute_with_retry(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, :invalid_input}
          end,
          max_attempts: 3,
          retriable_errors: [:timeout]
        )

      assert {:error, :invalid_input} = result
      assert :counters.get(counter, 1) == 1
    end
  end

  describe "execute_with_circuit_breaker/3" do
    setup do
      {:ok, cb} =
        Snakepit.CircuitBreaker.start_link(
          name: :"cb_exec_#{System.unique_integer([:positive])}",
          failure_threshold: 2,
          reset_timeout_ms: 100
        )

      on_exit(fn ->
        if Process.alive?(cb), do: GenServer.stop(cb)
      end)

      {:ok, cb: cb}
    end

    test "executes through circuit breaker", %{cb: cb} do
      result = Executor.execute_with_circuit_breaker(cb, fn -> {:ok, :success} end)
      assert result == {:ok, :success}
    end

    test "returns error when circuit open", %{cb: cb} do
      # Open the circuit
      Snakepit.CircuitBreaker.record_failure(cb)
      Snakepit.CircuitBreaker.record_failure(cb)

      result = Executor.execute_with_circuit_breaker(cb, fn -> {:ok, :success} end)
      assert result == {:error, :circuit_open}
    end
  end

  describe "execute_with_timeout/3" do
    test "returns result within timeout" do
      result =
        Executor.execute_with_timeout(
          fn ->
            {:ok, :success}
          end,
          timeout_ms: 1000
        )

      assert result == {:ok, :success}
    end

    test "returns timeout error when exceeded" do
      result =
        Executor.execute_with_timeout(
          fn ->
            receive do
              :complete -> {:ok, :success}
            end
          end,
          timeout_ms: 10
        )

      assert result == {:error, :timeout}
    end

    test "returns controlled error when task crashes" do
      result =
        Executor.execute_with_timeout(
          fn ->
            raise "boom"
          end,
          timeout_ms: Snakepit.Defaults.executor_batch_timeout()
        )

      assert match?({:error, {:task_crashed, _}}, result)
    end
  end

  describe "execute_async/2" do
    test "returns task reference" do
      task = Executor.execute_async(fn -> {:ok, :success} end)

      assert is_struct(task, Task)
      result = Task.await(task)
      assert result == {:ok, :success}
    end
  end

  describe "execute_batch/3" do
    test "executes functions in parallel" do
      functions = [
        fn -> {:ok, 1} end,
        fn -> {:ok, 2} end,
        fn -> {:ok, 3} end
      ]

      results = Executor.execute_batch(functions, timeout_ms: 5000)

      assert results == [{:ok, 1}, {:ok, 2}, {:ok, 3}]
    end

    test "handles mixed results" do
      functions = [
        fn -> {:ok, 1} end,
        fn -> {:error, :failed} end,
        fn -> {:ok, 3} end
      ]

      results = Executor.execute_batch(functions, timeout_ms: 5000)

      assert results == [{:ok, 1}, {:error, :failed}, {:ok, 3}]
    end
  end
end
