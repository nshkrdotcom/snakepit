You are working on the Snakepit codebase, a production-grade Elixir + Python system for pooled external workers, gRPC bridges, and session management.

The system is already:
- Architecturally solid and modular (Pool, GRPCWorker, ProcessRegistry, SessionStore, ToolRegistry, Telemetry, Python bridge).
- Well-documented with strong attention to resource hygiene, process cleanup, and telemetry.
- Covered by a substantial test suite (unit, integration, performance) and many working examples.

However, there are some high-complexity areas and subtle contracts that we want to harden, clarify, or verify. Your job is to address these *without regressing existing behavior* and *without breaking existing tests or examples*.

Assume:
- All tests under `test/` currently pass.
- All examples under `examples/` currently run as advertised.
- You can modify Elixir and Python code, tests, and docs.

Your goals are:

1) **Verify and, if needed, fix registry metadata semantics**

Context:
- `Snakepit.GRPCWorker.start_link/1` uses a via tuple like:
  ```elixir
  name =
    if worker_id do
      {:via, Registry, {Snakepit.Pool.Registry, worker_id, metadata}}
    else
      nil
    end
  ```

* `Snakepit.Pool.Registry` expects `Registry.lookup(@registry_name, worker_id)` to yield `{pid, metadata}`.
* Canonical usage in Elixir is usually `{:via, Registry, {RegistryName, key}}` with metadata set via `Registry.register/3`.

Tasks:

* Confirm how `Registry` is actually used in this project and OTP/Elixir version:

  * Is the 3-element tuple `{registry, key, metadata}` supported and behaving as intended?
  * Does `Registry.lookup/2` indeed return the metadata in all the places we rely on (e.g., `Pool.Registry.get_worker_id_by_pid/1`, `extract_pool_name_from_worker_id/1`, `get_worker_module/1`)?
* If the usage is non-standard or brittle:

  * Refactor registration so metadata is stored in the canonical way (e.g., via `Registry.register/3` in `GRPCWorker.init/1`), while preserving the existing API semantics.
  * Ensure `Pool.Registry.worker_exists?/1`, `get_worker_pid/1`, `get_worker_id_by_pid/1`, and any metadata consumers still behave the same logically.
* Add or extend unit tests in `test/unit/pool/pool_registry_lookup_test.exs` and any GRPCWorker tests to:

  * Prove that we can reliably read `worker_module`, `pool_identifier`, and other metadata for a registered worker.
  * Prove that reverse lookup (PID → worker_id) still works.

Acceptance criteria:

* Registry usage is idiomatic and clearly documented.
* All existing tests still pass, plus new tests that lock in the metadata behavior.
* Metadata-dependent code paths (pool-name extraction, channel reuse, worker profile helpers) work correctly and deterministically.

---

2. **Make memory-based recycling either real or explicit**

Context:

* `Snakepit.Worker.LifecycleManager` has `memory_threshold_mb` and `should_recycle_memory?/1`.
* `get_worker_memory_mb/1` assumes a worker responds to `GenServer.call(pid, :get_memory_usage)`.
* `Snakepit.GRPCWorker` does not currently implement `:get_memory_usage`, so memory-based recycling is effectively a no-op.

Tasks:

* Decide on one of two approaches (and implement it):

  **Option A – Implement real memory recycling:**

  * Add `handle_call(:get_memory_usage, _from, state)` to `Snakepit.GRPCWorker` that returns either:

    * `{:ok, bytes}` using `Process.info(self(), :memory)` to get BEAM memory usage for that worker process, or
    * A structured value if you prefer (but keep it simple).
  * Make sure `LifecycleManager.should_recycle_memory?/1` is now effective:

    * For workers with `memory_threshold_mb` set, when usage exceeds the threshold, recycling is triggered.
  * Add tests in `test/snakepit/pool/worker_lifecycle_test.exs` (or a new test file) that:

    * Configure a worker with a low `memory_threshold_mb`.
    * Simulate increased memory usage (can be via a mock worker or by stubbing `:get_memory_usage` in a `TestableGRPCWorker`).
    * Assert that `LifecycleManager` requests a recycle and that a replacement worker is started.

  **Option B – Explicitly mark memory recycling as not implemented (for now):**

  * Remove or guard `memory_threshold_mb` behavior so it’s clearly not active (e.g., log a warning once if configured, or ignore it explicitly).
  * Update documentation (`README.md`, `docs/performance_benchmarks.md` or lifecycle docs) to say memory-based recycling is planned but not currently implemented.
  * Make sure configuration examples do not advertise memory recycling as functional.

Acceptance criteria:

* Either memory-based recycling actually does something verifiable, or it is clearly documented and not silently “pretended”.
* Tests cover the chosen behavior.

---

3. **Clarify and potentially tighten rogue Python process cleanup**

Context:

* On startup and via `cleanup_rogue_processes/1`, we kill Python processes whose command contains `grpc_server.py` but not the current `run_id`.
* This is safe if Snakepit “owns” that filename, but dangerous if another service uses the same script name on the same host.

Tasks:

* Make the intent explicit in code and docs:

  * If Snakepit truly owns `grpc_server.py` and `grpc_server_threaded.py`, document this strongly in `README_PROCESS_MANAGEMENT.md` and/or `README_GRPC.md` (“do not reuse these names outside Snakepit on shared hosts”).
* Consider tightening the criteria:

  * For example, also require a recognizable marker (like `--snakepit-run-id` or a known environment variable pattern) instead of *only* `grpc_server.py` in the command line.
  * Or add a configuration flag to enable/disable rogue-process cleanup, defaulting to “safe” behavior.
* Add or refine tests in `test/snakepit/process_killer_test.exs`:

  * Simulate process commands that:

    * Include `grpc_server.py` and a different run_id → must be killed by `kill_by_run_id/1` for that run.
    * Include `grpc_server.py` but no run_id → must be treated according to your tightened rules and config.
    * Include random Python processes with other commands → must not be killed.
  * You can stub `get_process_command/1` to avoid spawning real processes in unit tests.

Acceptance criteria:

* Rogue cleanup behavior is explicit and predictable.
* Tests prove we don’t accidentally kill unrelated Python processes.
* The behavior is clearly documented for operators.

---

4. **Define and implement a clear semantics for `binary_parameters`**

Context:

* `ExecuteToolRequest` proto supports both `parameters` (map<string, Any>) and `binary_parameters` (map<string, bytes>).
* `Snakepit.GRPC.BridgeServer.decode_tool_parameters/1` currently only decodes `parameters` and ignores `binary_parameters`.

Tasks:

* Decide what we want `binary_parameters` to mean in the Elixir bridge:

  **Option A – Elixir never touches binary params (Python-only):**

  * Treat `binary_parameters` as opaque and forward them directly to the Python side:

    * Extend `BridgeServer.execute_tool` and `execute_tool_handler/3` so that when building the request for `Snakepit.GRPC.Client.execute_tool/5`, the decoded parameters map includes something like `"__binary__"` or a structured map that Python expects, OR…
    * Extend `Snakepit.GRPC.ClientImpl.execute_tool/5` to accept a separate `binary_parameters` argument and transmit it to the Python worker using the correct proto fields.
  * Clearly document that Elixir-side local tools won’t see `binary_parameters`.

  **Option B – Elixir tools can see binary params:**

  * Extend `decode_tool_parameters/1` to:

    * Decode both `parameters` and `binary_parameters`.
    * Return a combined map where binary params are represented as `{:binary, binary}` or similar.
  * Update `ToolRegistry.execute_local_tool/3` callers and/or docs to explain how to handle these binaries.

* Update tests:

  * Introduce a small test (e.g. in `test/unit/grpc/bridge_server_test.exs`) that creates an `ExecuteToolRequest` with both types and verifies the Elixir side behaves exactly as decided.
  * Add a Python integration test if needed (using the Python test harness) to verify end-to-end behavior.

Acceptance criteria:

* `binary_parameters` have a clearly defined behavior and are not silently ignored.
* Behavior is tested and documented.

---

5. **Address module size & reinforce integration tests around high-risk flows**

Context:

* `Snakepit.Pool`, `Snakepit.GRPCWorker`, and `Snakepit.Pool.ProcessRegistry` are very large and multi-responsibility. They are working but are harder to reason about.
* We already have many tests and examples, but complexity plus OS interactions mean we should lean heavily on nasty integration tests.

Tasks:

* You do NOT need to fully refactor these modules now, but you should:

  * Identify clearly separable pieces (e.g., queue management, worker spawn logic, resource delta calculations) and, if possible, extract them into pure helper modules or private helpers with focused tests.
  * Add or strengthen integration tests specifically around the most complex chains:

    * gRPC call → worker execution → pool checkout/checkin → process registry update → cleanup on shutdown.
    * Under client disconnects, timeouts, or worker crashes.

* Use property-like tests where it makes sense:

  * For example, tests that repeatedly:

    * Start Snakepit.
    * Fire random combinations of execute/execute_stream calls.
    * Randomly kill workers or terminate the application.
    * Assert that, at the end, no Python processes are left and pools are in a consistent state.
  * You can bound the randomness to keep tests deterministic and under reasonable runtime; consider using `StreamData` if you already depend on it.

Acceptance criteria:

* The worst “fear points” (multi-step kill chains, cancellation, and restart flows) are backed by explicit tests.
* Any small refactors you do reduce local complexity without changing external behavior.

---

6. **Decouple LifecycleManager’s config assumptions**

Context:

* `Snakepit.Worker.LifecycleManager.track_worker/4` and `start_replacement_worker/2` rely on the `config` map passed in containing certain keys (e.g. `:worker_profile`, `:worker_module`, `:adapter_module`, etc.).
* This is currently true because pool code passes full pool configs, but this is an implicit contract.

Tasks:

* Introduce a small, explicit “lifecycle config” structure or documented shape:

  * e.g. a struct like:

    ```elixir
    defmodule Snakepit.Worker.LifecycleConfig do
      defstruct [:pool_name, :worker_profile, :worker_module, :adapter_module, :adapter_args, :adapter_env, :worker_ttl, :worker_max_requests, :memory_threshold_mb]
    end
    ```

    or a clearly documented map contract.

* Ensure:

  * Pool code constructs this config once and passes it to `LifecycleManager.track_worker/4`.
  * `start_replacement_worker/2` consumes the same shape deterministically.

* Update tests in `test/snakepit/pool/worker_lifecycle_test.exs` and `test/unit/worker_profile/worker_profile_stop_worker_test.exs` (and others as needed) to:

  * Assert that recycling uses the same profile and adapter configuration as initial start.
  * Guard against future regressions where a field might accidentally be omitted.

Acceptance criteria:

* The shape of lifecycle config is explicit and not “magic”.
* Replacement workers are guaranteed to be started with consistent settings.

---

7. **Document the complexity & trade-offs clearly**

Finally, update documentation to reflect reality and to help future maintainers:

Tasks:

* In `ARCHITECTURE.md` or a similar doc:

  * Acknowledge the complexity of `Snakepit.Pool`, `GRPCWorker`, and `ProcessRegistry`, and briefly explain why they’re this way (to handle OS quirks, orphan cleanup, multi-pool, etc.).
  * Summarize the kill chains and cleanup responsibilities (Pool → Worker → ProcessRegistry → ProcessKiller → ApplicationCleanup).
* In `README_PROCESS_MANAGEMENT.md` and/or `README_GRPC.md`:

  * Document the assumptions behind run IDs, script names, and rogue cleanup behavior.
  * Document heartbeat modes (dependent vs independent) and their consequences.
* Make sure the “Verdict” sentiment is addressed: that we now have:

  * A clear contract around Registry metadata.
  * Either working or clearly disabled memory recycling.
  * Explicit semantics for rogue cleanup and binary parameters.
  * Stronger tests around high-risk flows.

Acceptance criteria:

* Docs are up-to-date with the actual behavior and design decisions.
* A new engineer reading the docs plus tests can understand the “dangerous” parts of the system and how they’re guarded.

---

General requirements:

* Keep all existing tests and examples passing.
* For every new behavior you introduce or clarify, add tests.
* For every contract that was previously “implicit” (registry metadata, lifecycle config, binary params, rogue cleanup), make it explicit in code and docs.
* When in doubt between “hide complexity” and “document complexity”, prefer to document and test it rather than trying to over-simplify.

When you are done, produce:

* A list of code changes (per file, high-level).
* A list of new/updated tests with a one-line description each.
* A short summary of any behavior changes and how they’re covered by tests and docs.

