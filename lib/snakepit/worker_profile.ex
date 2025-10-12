defmodule Snakepit.WorkerProfile do
  @moduledoc """
  Behaviour for worker profiles (process vs thread).

  A worker profile defines how workers are created, managed, and utilized.
  Snakepit v0.6.0 introduces dual-mode parallelism:

  ## Process Profile (`:process`)
  - Many single-threaded Python processes
  - Process isolation and GIL compatibility
  - Optimal for: I/O-bound workloads, high concurrency, legacy Python

  ## Thread Profile (`:thread`)
  - Few multi-threaded Python processes
  - Shared memory and CPU parallelism
  - Optimal for: CPU-bound workloads, Python 3.13+, large data

  ## Implementing a Profile

  Profiles control the full worker lifecycle:

      defmodule MyProfile do
        @behaviour Snakepit.WorkerProfile

        def start_worker(config) do
          # Start worker according to profile
          {:ok, worker_handle}
        end

        def get_capacity(worker_handle) do
          # Return concurrent request capacity
          1  # or N for multi-threaded
        end
      end

  See `Snakepit.WorkerProfile.Process` and `Snakepit.WorkerProfile.Thread` for reference implementations.
  """

  @type worker_handle :: pid() | reference()
  @type config :: map()
  @type capacity :: pos_integer()

  @doc """
  Start a worker with the given configuration.

  Returns `{:ok, worker_handle}` where worker_handle is typically a GenServer PID,
  or `{:error, reason}` if startup fails.

  The config map contains all pool and adapter configuration for this worker.
  """
  @callback start_worker(config) :: {:ok, worker_handle} | {:error, term()}

  @doc """
  Stop a worker gracefully.

  Should perform cleanup and shutdown the worker process.
  """
  @callback stop_worker(worker_handle) :: :ok

  @doc """
  Execute a request on a worker.

  For process-based workers, this typically blocks until the request completes.
  For thread-based workers, this may execute concurrently with other requests
  on the same worker.

  The timeout is in milliseconds.
  """
  @callback execute_request(worker_handle, request :: map(), timeout :: timeout()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Get the maximum capacity of a worker (how many concurrent requests it can handle).

  - Process profile: returns 1 (single-threaded)
  - Thread profile: returns N (thread pool size)

  This is used by the pool for load balancing decisions.
  """
  @callback get_capacity(worker_handle) :: capacity()

  @doc """
  Get the current load of a worker (how many requests are currently in-flight).

  Returns 0 if no requests are active, up to the worker's capacity.
  """
  @callback get_load(worker_handle) :: non_neg_integer()

  @doc """
  Check if a worker is healthy and responsive.

  Returns `:ok` if healthy, `{:error, reason}` if unhealthy.
  """
  @callback health_check(worker_handle) :: :ok | {:error, term()}

  @doc """
  Get profile-specific metadata about a worker.

  Optional callback. Returns a map with profile-specific information.
  """
  @callback get_metadata(worker_handle) :: {:ok, map()} | {:error, term()}

  @optional_callbacks [get_metadata: 1]
end
