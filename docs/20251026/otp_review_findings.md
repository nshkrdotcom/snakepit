# Snakepit OTP Review — Findings & Remediation Plan

- **Date:** 2025-10-26
- **Author:** Codex reviewer pass 1
- **Scope:** Elixir core (`lib/`) with emphasis on OTP structure, worker lifecycle, and deployment readiness.

## 1. Executive Summary

The current OTP core is close to production-ready, but three high-severity issues block safe releases:

1. Release boot will crash because `Mix.env()` is invoked inside the running application (`lib/snakepit/application.ex:67`).
2. Worker shutdown APIs route to the wrong supervisor children, so failed workers stay alive (`lib/snakepit/pool/worker_supervisor.ex:75`).
3. Profile-level `stop_worker/1` helpers attempt to look up registries by PID, which never matches and prevents graceful teardown (`lib/snakepit/worker_profile/process.ex:72`, `lib/snakepit/worker_profile/thread.ex:116`).

A medium-severity configuration hazard (partial thread-limit overrides) should be addressed alongside the high-priority work to avoid regressions.

## 2. Detailed Findings

### 2.1 Release Startup Regression

- **Location:** `lib/snakepit/application.ex:67`
- **Problem:** `Mix.env()` is evaluated during `Snakepit.Application.start/2`. `Mix` is not bundled in releases, causing an `UndefinedFunctionError` when the supervisor tree boots under `:prod`.
- **Impact:** Release builds crash immediately; pool never starts.

### 2.2 WorkerSupervisor Stop/Restart Bug

- **Locations:** `lib/snakepit/pool/worker_supervisor.ex:75` and `:104`
- **Problem:** `stop_worker/1` and `restart_worker/1` look up the *worker* GenServer PID and pass it to `DynamicSupervisor.terminate_child/2`. The dynamic supervisor actually owns the worker **starter** supervisors, so `terminate_child/2` returns `{:error, :not_found}` and the worker continues running.
- **Impact:** Crashed or leaked workers remain alive, undermining lifecycle guarantees and any recycle logic. Restart requests from operations teams silently fail.

### 2.3 WorkerProfile Stop Helpers Are No-Ops

- **Locations:** `lib/snakepit/worker_profile/process.ex:72`, `lib/snakepit/worker_profile/thread.ex:116`
- **Problem:** The profile modules call `Registry.lookup(Snakepit.Pool.Registry, worker_pid)`. Registry keys are string worker IDs, so lookups by PID always miss. The helpers therefore do nothing and leaked workers accumulate whenever the profile passes a PID handle.
- **Impact:** Breaks lifecycle manager expectations, complicates zero-copy/threaded profiles, and exacerbates issue 2.2.

### 2.4 Thread-Limit Configuration Trap (Medium)

- **Location:** `lib/snakepit/application.ex:37-44`
- **Problem:** `thread_limits.openblas` (dot access) is used after `Application.get_env/3`. User configs that override only a subset of keys cause `KeyError` at boot.
- **Impact:** Partial overrides crash the app; behaviour is surprising for operators tweaking a single library.

## 3. Recommended Remediations

| Priority | Workstream | Key Actions | Owners (suggested) |
|----------|------------|-------------|--------------------|
| P0 | Release safety | Replace `Mix.env()` call with `Application.compile_env(:snakepit, :environment, :prod)` or pre-computed value; adjust logs to avoid runtime `Mix`. | Platform |
| P0 | Worker lifecycle | Change termination logic to target the worker starter supervisor (fetch via `Snakepit.Pool.Worker.StarterRegistry` or by inspecting children), ensure restart path uses the same handle, and add regression tests in `test/snakepit/pool/worker_supervisor_test.exs`. | Runtime |
| P0 | Profile helpers | Update `stop_worker/1` clauses to accept both worker IDs and PIDs by deriving the ID through registry metadata or `Snakepit.Pool.Registry.get_worker_id_by_pid/1`; add new unit tests. | Runtime |
| P1 | Config ergonomics | Merge `:python_thread_limits` with defaults via `Map.merge/2` or `Map.get/3` fallback before calling `System.put_env/2`. | Platform |

## 4. Testing & Verification Strategy

1. **WorkerSupervisor regression tests:** Add integration cases where `start_worker/1` followed by `stop_worker/1` asserts the starter process exits and the registry entry clears. Include restart coverage with a synthetic worker crash.
2. **Profile unit tests:** Ensure both `:process` and `:thread` profiles correctly stop workers when passed either a PID or string ID.
3. **Release smoke test:** Build a `MIX_ENV=prod mix release` and run `./bin/snakepit start` to confirm the supervisor boots without `Mix` access.
4. **Configuration test:** Add `config/test/support/python_threads_partial.exs` (or equivalent) to validate partial overrides do not crash and environment variables are applied as expected.

## 5. Rollout Considerations

- **Backward compatibility:** Changes are internal and do not alter public APIs except improving previously broken paths. No client-facing contract adjustments are required.
- **Operational notes:** Coordinate with infra to validate the fix in staging using the highest worker counts to ensure cleanup logic still scales.
- **Documentation updates:** Update `docs/code-standards/release_checklist.md` (or equivalent) with guidance on avoiding runtime `Mix` calls, and mention the partial override behaviour in `README_TESTING.md`.

## 6. Open Question Responses

| Question | Answer |
|----------|--------|
| Do we already have integration tests that exercise `Snakepit.Pool.WorkerSupervisor.stop_worker/1`? | **No, but we need them.** |
| Should partial overrides of `:python_thread_limits` be supported? | **Yes, partial overrides are a useful feature.** |

## 7. Next Steps

1. Land the four remediation tasks above, targeting a patch release (v0.6.x hotfix).
2. Backfill automated coverage so regressions fail CI instead of production.
3. Re-run the OTP review to confirm no additional lifecycle gaps remain before tackling v0.7+ roadmap work.

