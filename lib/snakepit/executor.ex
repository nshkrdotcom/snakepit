defmodule Snakepit.Executor do
  @moduledoc """
  Execution helpers with retry, circuit breaker, and timeout support.

  Provides various execution strategies for running operations
  with fault tolerance.

  ## Usage

      # Simple execution with retry
      result = Executor.execute_with_retry(
        fn -> risky_operation() end,
        max_attempts: 3,
        backoff_ms: [100, 200, 400]
      )

      # With circuit breaker
      result = Executor.execute_with_circuit_breaker(cb, fn ->
        external_call()
      end)

      # With timeout
      result = Executor.execute_with_timeout(
        fn -> slow_operation() end,
        timeout_ms: 5000
      )
  """

  alias Snakepit.{CircuitBreaker, Defaults, RetryPolicy}
  alias Snakepit.Internal.TimeoutRunner

  @doc """
  Executes a function directly.
  """
  @spec execute((-> any()), keyword()) :: any()
  def execute(fun, _opts \\ []) when is_function(fun, 0) do
    fun.()
  end

  @doc """
  Executes a function with retry on transient failures.

  ## Options

  - `:max_attempts` - Maximum attempts (default: 3)
  - `:backoff_ms` - List of backoff delays (default: [100, 200, 400])
  - `:retriable_errors` - Errors to retry (default: [:timeout, :unavailable])
  - `:jitter` - Add random jitter (default: false)
  """
  @spec execute_with_retry((-> any()), keyword()) :: any()
  def execute_with_retry(fun, opts \\ []) when is_function(fun, 0) do
    policy = RetryPolicy.new(opts)
    do_retry(fun, policy, 1)
  end

  defp do_retry(fun, policy, attempt) do
    result = fun.()

    cond do
      match?({:ok, _}, result) or match?(:ok, result) ->
        emit_retry_success(policy, attempt)
        result

      RetryPolicy.retry_for_error?(policy, result) and
          RetryPolicy.should_retry?(policy, attempt) ->
        delay = RetryPolicy.backoff_for_attempt(policy, attempt)
        emit_retry_attempt(policy, attempt, delay)
        Process.sleep(delay)
        do_retry(fun, policy, attempt + 1)

      RetryPolicy.should_retry?(policy, attempt) == false ->
        emit_retry_exhausted(policy, attempt, result)
        result

      true ->
        # Non-retriable error
        result
    end
  end

  @doc """
  Executes a function through a circuit breaker.
  """
  @spec execute_with_circuit_breaker(GenServer.server(), (-> any()), keyword()) :: any()
  def execute_with_circuit_breaker(circuit_breaker, fun, _opts \\ [])
      when is_function(fun, 0) do
    CircuitBreaker.call(circuit_breaker, fun)
  end

  @doc """
  Executes a function with a timeout.

  Returns `{:error, :timeout}` if the function doesn't complete in time.

  ## Options

  - `:timeout_ms` - Timeout in milliseconds (required)
  """
  @spec execute_with_timeout((-> any()), keyword()) :: any()
  def execute_with_timeout(fun, opts) when is_function(fun, 0) do
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)

    case run_with_timeout(fun, timeout_ms) do
      {:ok, result} ->
        result

      :timeout ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, {:task_crashed, reason}}
    end
  end

  @doc """
  Executes a function asynchronously.

  Returns a Task that can be awaited.
  """
  @spec execute_async((-> any()), keyword()) :: Task.t()
  def execute_async(fun, _opts \\ []) when is_function(fun, 0) do
    Task.async(fun)
  end

  @doc """
  Executes multiple functions in parallel.

  Returns results in the same order as the input functions.

  ## Options

  - `:timeout_ms` - Timeout for all operations (default: 30000)
  - `:max_concurrency` - Maximum concurrent operations (default: unlimited)
  """
  @spec execute_batch([(-> any())], keyword()) :: [any()]
  def execute_batch(functions, opts \\ []) when is_list(functions) do
    timeout_ms = Keyword.get(opts, :timeout_ms, Defaults.executor_batch_timeout())
    max_concurrency = Keyword.get(opts, :max_concurrency, length(functions))

    functions
    |> Task.async_stream(
      fn fun -> fun.() end,
      max_concurrency: max_concurrency,
      timeout: timeout_ms
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:exit, reason}}
    end)
  end

  @doc """
  Executes with retry and circuit breaker.

  Combines retry logic with circuit breaker protection.
  """
  @spec execute_with_protection(GenServer.server(), (-> any()), keyword()) :: any()
  def execute_with_protection(circuit_breaker, fun, opts \\ []) do
    execute_with_retry(
      fn -> execute_with_circuit_breaker(circuit_breaker, fun) end,
      opts
    )
  end

  # Telemetry helpers

  defp emit_retry_attempt(_policy, attempt, delay) do
    :telemetry.execute(
      [:snakepit, :retry, :attempt],
      %{attempt: attempt, delay_ms: delay},
      %{pool: nil, operation: nil}
    )
  end

  defp emit_retry_success(_policy, attempts) do
    :telemetry.execute(
      [:snakepit, :retry, :success],
      %{attempts: attempts, total_duration: 0},
      %{pool: nil}
    )
  end

  defp emit_retry_exhausted(_policy, attempts, error) do
    :telemetry.execute(
      [:snakepit, :retry, :exhausted],
      %{attempts: attempts, total_duration: 0},
      %{pool: nil, last_error: error}
    )
  end

  defp run_with_timeout(fun, timeout_ms) when is_function(fun, 0) and is_integer(timeout_ms) do
    TimeoutRunner.run(fun, timeout_ms)
  end
end
