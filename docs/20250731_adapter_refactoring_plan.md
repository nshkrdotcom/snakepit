# Snakepit.Adapter Behaviour Refactoring Plan (Detailed)

- **Date**: 2025-07-31
- **Status**: Proposed
- **Author**: Gemini Engineering Expert

## 1. Objective

This document provides a detailed, step-by-step plan to refactor the `Snakepit` codebase. The goal is to implement the revised `Snakepit.Adapter` behaviour as specified in `docs/20250730_behaviour.md`. This change is critical for system robustness, replacing a flexible but brittle "cognitive" interface with a strict, process-oriented contract.

## 2. Core Changes Summary

The refactoring introduces three fundamental changes to the architecture:

1.  **Strict `start_worker` Contract**: The adapter's `start_worker/2` function will now be responsible for spawning the external OS process and **must** return its actual OS PID. `Snakepit` will use this OS PID for reliable tracking and cleanup, a significant improvement over tracking Elixir PIDs.
2.  **Signal-Based Startup**: All forms of timer-based waiting (`Process.sleep`) for worker readiness are now forbidden. The adapter must implement a deterministic, signal-based handshake (e.g., listening for a "ready" message on STDOUT) to ensure a worker is fully initialized before it's added to the pool.
3.  **Interface Simplification**: The adapter behaviour is being streamlined to focus exclusively on process lifecycle and communication. All "cognitive" and streaming-specific callbacks are removed, clarifying the core responsibility of both the adapter and the `snakepit` engine.

---

## 3. Detailed Refactoring Steps

### Step 3.1: Redefine the `Snakepit.Adapter` Behaviour

The first step is to update the `Snakepit.Adapter` module to reflect the new, stricter contract. This is the foundation for all subsequent changes.

-   **File:** `/home/home/p/g/n/dspex/snakepit/lib/snakepit/adapter.ex`
-   **Action:** The entire content of the file will be replaced.

**New Content for `lib/snakepit/adapter.ex`:**
```elixir
defmodule Snakepit.Adapter do
  @moduledoc """
  The behaviour (interface) for a Snakepit worker adapter.

  This contract defines the "perfect seam" between the generic `snakepit`
  infrastructure and a specific runtime implementation (like Python/gRPC).
  `snakepit` knows nothing about the implementation; it only calls the
  functions defined in this contract.
  """

  @typedoc "The opaque state managed by the adapter for a single worker."
  @type handle :: any()

  @typedoc "The opaque state managed by the adapter for the entire pool."
  @type adapter_state :: any()

  @doc """
  Called once when the pool starts.

  This function should be used to initialize any shared resources the adapter
  needs, such as starting an Elixir-side gRPC server for callbacks.
  """
  @callback init(config :: keyword()) :: {:ok, adapter_state} | {:error, any()}

  @doc """
  Starts one external worker process and returns a handle to it.

  This is the most critical hook in the system. The implementation MUST
  return the actual OS-level Process ID (PID) of the spawned worker.
  `snakepit` uses this OS PID to track the process and guarantee cleanup
  of orphaned processes, but it remains entirely ignorant of how the
  process was started.

  The returned `handle` is opaque to `snakepit` and is passed back to
  all other adapter callbacks for this specific worker.
  """
  @callback start_worker(worker_id :: term(), adapter_state :: adapter_state) ::
              {:ok, os_pid :: pid(), handle} | {:error, any()}

  @doc """
  Executes a command on a specific worker.

  `snakepit` calls this function to delegate a task to the worker. The adapter
  is responsible for serializing the command and arguments, sending them
  over the transport, and deserializing the response.
  """
  @callback execute(handle, command :: String.t(), args :: map()) ::
              {:ok, result :: any()} | {:error, any()}

  @doc """
  Called when a worker process is being shut down.

  This function should gracefully terminate the worker process and clean up
  any resources associated with the specific `handle`, such as closing
  network connections or ports.
  """
  @callback terminate(handle, reason :: term()) :: :ok
end
```

### Step 3.2: Overhaul `Snakepit.GenericWorker`

The `GenericWorker` is the heart of the system and requires the most significant changes. It will now drive the `start_worker` call and manage the resulting `handle`.

-   **File:** `/home/home/p/g/n/dspex/snakepit/lib/snakepit/generic_worker.ex`
-   **Action:** Substantial modification of the `defstruct`, `init/1`, `handle_call/3` for `:execute`, and `terminate/2` functions.

**Detailed Changes:**

1.  **Update `defstruct` (Line ~11):** The worker state will no longer hold `adapter_state`; it will hold the `handle` for a specific worker instance.

    *   **From:** `defstruct [:id, :adapter_module, :adapter_state, :stats]`
    *   **To:** `defstruct [:id, :adapter_module, :handle, :os_pid, :stats]`

2.  **Update `start_link/1` (Line ~19):** The arguments passed to `GenServer.start_link` must be updated to include the `adapter_state`.

    *   **From:** `GenServer.start_link(__MODULE__, {worker_id, adapter_module})`
    *   **To:** `GenServer.start_link(__MODULE__, {worker_id, adapter_module, adapter_state})` (Note: `adapter_state` will need to be passed in from the `Pool`).

3.  **Rewrite `init/1` (Line ~60):** This function is completely changed to orchestrate the new startup sequence.

    *   **From (Conceptual):** Validates adapter, initializes it, registers Elixir PID.
    *   **To (New Logic):**
        ```elixir
        # apps/snakepit/lib/snakepit/generic_worker.ex

        @impl true
        def init({worker_id, adapter_module, adapter_state}) do
          Logger.debug("GenericWorker #{worker_id} starting with adapter #{inspect(adapter_module)}")

          # 1. Delegate worker creation to the adapter
          case adapter_module.start_worker(worker_id, adapter_state) do
            {:ok, os_pid, handle} ->
              # 2. Register the OS PID for supervision
              Snakepit.Pool.ProcessRegistry.register_os_pid(self(), os_pid)

              state = %__MODULE__{
                id: worker_id,
                adapter_module: adapter_module,
                handle: handle, # Store the handle
                os_pid: os_pid, # Store the OS PID
                stats: %{commands_executed: 0, errors: 0}
              }
              Logger.info("Generic worker #{worker_id} (OS PID: #{inspect(os_pid)}) started successfully.")
              {:ok, state}

            {:error, reason} ->
              Logger.error("Adapter failed to start worker #{worker_id}: #{inspect(reason)}")
              {:stop, {:adapter_start_worker_failed, reason}}
          end
        end
        ```

4.  **Simplify `handle_call` for `:execute` (Line ~95):** The signature is simplified, and it now uses the `handle` from the state.

    *   **From:** `def handle_call({:execute, command, args, opts}, _from, state)`
    *   **To:**
        ```elixir
        # apps/snakepit/lib/snakepit/generic_worker.ex

        @impl true
        def handle_call({:execute, command, args}, _from, state) do
          result = state.adapter_module.execute(state.handle, command, args)
          # Stats logic can remain, but simplified
          # ...
          {:reply, result, state}
        end
        ```

5.  **Remove `handle_call` for `:execute_stream` (Line ~118):** This callback is no longer part of the adapter behaviour.

6.  **Update `terminate/2` (Line ~150):** The terminate function must now pass the `handle` to the adapter.

    *   **From:** `state.adapter_module.terminate(reason, state.adapter_state)`
    *   **To:** `state.adapter_module.terminate(state.handle, reason)`

### Step 3.3: Adapt `Snakepit.Pool` to the New Lifecycle

The `Pool`'s responsibility shifts slightly. It now orchestrates the adapter's global `init/1` call and passes the resulting `adapter_state` to the workers it supervises.

-   **File:** `/home/home/p/g/n/dspex/snakepit/lib/snakepit/pool/pool.ex`
-   **Action:** Modify `init/1` and the worker startup logic.

**Detailed Changes:**

1.  **Modify `init/1` (Line ~175):** The pool must now call `adapter.init/1` and store the state.

    *   **Action:** Add the `init` call and store its result in the pool's state.
    *   **New Logic Snippet:**
        ```elixir
        # apps/snakepit/lib/snakepit/pool/pool.ex in init/1

        adapter_module = opts[:adapter_module] || Application.get_env(:snakepit, :adapter_module)

        # Call adapter.init/1 once for the entire pool
        case adapter_module.init(Application.get_env(:snakepit, :adapter_config, [])) do
          {:ok, adapter_state} ->
            # ... proceed with state initialization ...
            state = %__MODULE__{
              # ... other fields
              adapter_module: adapter_module,
              adapter_state: adapter_state
            }
            {:ok, state, {:continue, :initialize_workers}}

          {:error, reason} ->
            Logger.error("Failed to initialize adapter #{inspect(adapter_module)}: #{inspect(reason)}")
            {:stop, {:adapter_init_failed, reason}}
        end
        ```

2.  **Update `start_workers_concurrently` (Line ~450):** This function must be updated to pass the `adapter_state` to the `WorkerSupervisor`.

    *   **Action:** Modify the call to `Snakepit.Pool.WorkerSupervisor.start_worker`.
    *   **From:** `Snakepit.Pool.WorkerSupervisor.start_worker(worker_id, worker_module, adapter_module)`
    *   **To:** `Snakepit.Pool.WorkerSupervisor.start_worker(worker_id, worker_module, adapter_module, adapter_state)`

### Step 3.4: Create a New, Robust Mock Adapter for Testing

To properly test the new, stricter contract, a new mock adapter is essential. This adapter will correctly implement the new behaviour and serve as a reference.

-   **File:** `/home/home/p/g/n/dspex/snakepit/test/support/signal_mock_adapter.ex`
-   **Action:** Create a new file with the following content.

**New Content for `test/support/signal_mock_adapter.ex`:**
```elixir
defmodule Snakepit.Test.Support.SignalMockAdapter do
  @moduledoc """
  A mock adapter that correctly implements the new Snakepit.Adapter behaviour
  for testing purposes. It simulates a signal-based startup.
  """
  @behaviour Snakepit.Adapter

  # The handle now contains the worker_id for test assertions
  defstruct handle(worker_id: nil)

  @impl Snakepit.Adapter
  def init(_config) do
    # Simulate initializing a shared resource, like a GenServer or ETS table.
    {:ok, %{initialized_at: DateTime.utc_now()}}
  end

  @impl Snakepit.Adapter
  def start_worker(worker_id, _adapter_state) do
    # 1. Simulate spawning an OS process. In a real adapter, this would
    #    use Port.open/2 to run an external script.
    simulated_os_pid = :erlang.unique_integer([:positive])

    # 2. Simulate a short delay for the worker to become ready.
    #    A real adapter would listen on the Port for a "ready" message.
    :timer.sleep(10)

    # 3. Create the opaque handle for this worker.
    handle = %__MODULE__.handle{worker_id: worker_id}

    # 4. Return the OS PID and the handle, fulfilling the contract.
    {:ok, simulated_os_pid, handle}
  end

  @impl Snakepit.Adapter
  def execute(handle, command, args) do
    # Simulate doing work and returning a result.
    :timer.sleep(5)
    {:ok, %{
      message: "Executed command '#{command}'",
      handle_worker_id: handle.worker_id,
      args_received: args
    }}
  end

  @impl Snakepit.Adapter
  def terminate(_handle, _reason) do
    # Simulate cleaning up resources for a single worker.
    :ok
  end
end
```

---

## 4. Validation Plan

A multi-step validation process will ensure the refactoring is successful and robust.

1.  **Compile-Time Check:** After applying the changes, the first step is to run `mix compile --warnings-as-errors`. This will catch any function signature mismatches or other compile-time issues.
2.  **Update Existing Tests:** Many existing tests will fail due to the changed interfaces. These tests must be updated to use the new `SignalMockAdapter` and reflect the new API.
3.  **Create New Integration Test:** A new, dedicated integration test will be created to validate the end-to-end success of the new architecture.
    -   **New File:** `/home/home/p/g/n/dspex/snakepit/test/integration/new_adapter_lifecycle_test.exs`
    -   **Test Logic:**
        -   Start a `Snakepit.Pool` configured with the `SignalMockAdapter`.
        -   Use `Snakepit.Pool.await_ready/1` to confirm the pool initializes correctly.
        -   Use `Snakepit.Pool.list_workers/1` to get the list of worker IDs.
        -   Verify using `Snakepit.Pool.ProcessRegistry` that each worker has a registered OS PID.
        -   Execute a command using `Snakepit.Pool.execute/2` and assert that the result is `{:ok, ...}` and contains the expected payload from the mock adapter.
        -   Stop the pool and ensure a clean shutdown.
4.  **Manual Verification (Optional but Recommended):** Manually inspect the logs during test runs to ensure the new log messages related to worker startup, OS PID registration, and adapter initialization are present and correct.
