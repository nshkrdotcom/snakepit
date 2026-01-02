# Planning: Design Changes for 0.9.0

This plan proposes a focused, high-confidence refactor for 0.9.0 that improves
script lifecycle reliability and shutdown semantics without broad API churn.

## 1) Goals

- Deterministic script lifecycle: start, run, cleanup, exit in a predictable
  order.
- Safe shutdown under broken pipes and wrapper commands (timeout, head).
- Ownership-aware teardown: do not stop what you did not start.
- Preserve backward compatibility where possible.
- Explicitly document exit semantics and recommended usage.

## 2) Proposed changes (core runtime)

### 2.1 Exit policy API for run_as_script/2

Introduce an explicit exit policy with minimal API churn:

- New option: :exit_mode (atom)
  - :none (default) - return after cleanup, no VM exit.
  - :halt - hard exit (System.halt), no IO before exit.
  - :stop - graceful VM shutdown (System.stop), block after request.
  - :auto (deterministic) - resolves to :stop only when BOTH (a) this
    run_as_script/2 invocation started :snakepit (ownership = started) AND
    (b) the VM is running with --no-halt (detected via
    :init.get_argument(:no_halt)). In all other cases, resolves to :none.
    No wrapper-specific detection (timeout/systemd/pipes) is attempted.

Compatibility:

- Keep :halt boolean for backward compatibility.
- If :halt is true and :exit_mode is not set, treat as :halt.
- If :exit_mode is set, ignore :halt to avoid ambiguity.
- Continue honoring SNAKEPIT_SCRIPT_HALT but deprecate in favor of
  SNAKEPIT_SCRIPT_EXIT (string: none|halt|stop|auto).

#### Exit Selection Precedence (authoritative)

The runtime MUST resolve the effective `exit_mode` using the first applicable
rule below (highest wins). This table is the single source of truth for docs
and tests.

| Priority | Source                                | Input                              | Effective `exit_mode`                 | Notes                                                   |
| -------- | ------------------------------------- | ---------------------------------- | ------------------------------------- | ------------------------------------------------------- |
| 1        | `:exit_mode` option                   | `:none | :stop | :halt | :auto`     | as provided                           | Invalid atom -> raise `ArgumentError` (fail fast).      |
| 2        | legacy `:halt` option                 | `true | false`                     | `:halt` if `true`; otherwise continue | Only evaluated when `:exit_mode` is unset.              |
| 3        | `SNAKEPIT_SCRIPT_EXIT` env var        | string                             | parsed value                          | Only evaluated when `:exit_mode` and `:halt` are unset. |
| 4        | legacy `SNAKEPIT_SCRIPT_HALT` env var | truthy string                      | `:halt` if truthy; otherwise continue | Deprecated in 0.9.0; retained for compatibility.        |
| 5        | default                               | n/a                                | `:none`                               | Return normally after cleanup.                          |

##### `SNAKEPIT_SCRIPT_EXIT` parsing rules (authoritative)

* Read `SNAKEPIT_SCRIPT_EXIT` only when higher-precedence options do not set
  an exit policy.
* Parsing is case-insensitive and whitespace-tolerant: trim then lowercase.
* Accepted values: `none`, `halt`, `stop`, `auto`.
* Empty string is treated as "unset".
* Invalid value: ignore (treat as unset) and emit a pre-shutdown Logger
  warning that includes the invalid value and the fallback used.

##### Legacy `SNAKEPIT_SCRIPT_HALT` parsing rules (authoritative)

* Treat as truthy iff the trimmed, lowercased value is one of: `1`, `true`,
  `yes`, `y`, `on`.
* Any other value is false.
* This env var is deprecated in favor of `SNAKEPIT_SCRIPT_EXIT=halt`.

##### Status Code Rules (authoritative)

Define `status` from the user function outcome:

* If the user function returns normally: `status = 0`.
* If the user function raises/throws/exits: `status = 1` (do not print;
  re-raise after shutdown policy is applied unless the VM exits).

Apply `status` as follows:

* `exit_mode: :halt` -> `System.halt(status)` after cleanup; perform no IO in
  the exit path.
* `exit_mode: :stop` -> `System.stop(status)` after cleanup; then block the
  caller (e.g., `Process.sleep(:infinity)`) until VM shutdown completes.
* `exit_mode: :none` -> return/raise normally; Snakepit does not force VM
  termination.
* `exit_mode: :auto` -> resolve to `:stop` or `:none` per the deterministic
  rule above; then apply the corresponding behavior.

Rationale:

- Exposes intent instead of a binary, avoids forced hard exit in embedded
  contexts, and allows a future migration away from hard halts.

### 2.2 IO-safe exit path

- Remove all direct IO in the exit path (no :io.put_chars or :io.format).
- Use Logger for pre-exit diagnostics only when safe; guard with a config flag
  if needed.

Rationale:

- Prevent hang or deadlock when stdout/stderr is closed or piped.

### 2.3 Ownership-aware start/stop

- Track whether Snakepit was started by run_as_script/2.
  - Application.ensure_all_started/1 returns the list of newly-started apps.
  - Only call Application.stop(:snakepit) if Snakepit was started in this call
    or if an explicit override is provided.

- Add option: :stop_mode
  - :if_started (default)
  - :always
  - :never

Rationale:

- Prevents run_as_script from shutting down Snakepit when used inside a
  long-lived host application.

#### `stop_mode` x `exit_mode` interaction (authoritative)

`stop_mode` controls whether Snakepit is stopped (OTP application), while
`exit_mode` controls whether the entire VM exits. These are independent axes.

Definitions:

* **Owned** = this `run_as_script/2` invocation started `:snakepit` (via
  `Application.ensure_all_started/1` and `:snakepit` appears in the returned
  "started apps" list).
* **Embedded** = `:snakepit` was already running before `run_as_script/2`.

| Context              | stop_mode               | exit_mode         | Expected behavior                                             | Guidance                                                               |
| -------------------- | ----------------------- | ----------------- | ------------------------------------------------------------- | ---------------------------------------------------------------------- |
| Standalone (Owned)   | `:if_started` (default) | `:none` (default) | Stop Snakepit, run cleanup, return; script runner may exit VM | Recommended for most scripts.                                          |
| Standalone (Owned)   | `:if_started`           | `:stop`           | Stop Snakepit, run cleanup, request VM shutdown with status   | Recommended for `--no-halt` contexts.                                  |
| Standalone (Owned)   | `:if_started`           | `:halt`           | Stop Snakepit, run cleanup, hard halt VM with status          | Only for explicit operator intent.                                     |
| Standalone (Owned)   | `:if_started`           | `:auto`           | If `--no-halt` present -> behaves as `:stop`; else `:none`    | Recommended "safe default" for scripts that may run under `--no-halt`. |
| Embedded (Not owned) | `:if_started` (default) | `:none`           | Do not stop Snakepit; run cleanup for this run only; return   | Recommended for library embedding.                                     |
| Embedded (Not owned) | `:always`               | any               | Stops Snakepit even though not owned                          | Strongly discouraged; violates ownership boundaries.                   |
| Embedded (Not owned) | any                     | `:stop` / `:halt` | Stops entire VM                                               | Invalid for embedded usage; docs must warn against it.                 |
| Embedded (Not owned) | any                     | `:auto`           | MUST resolve to `:none` even if `--no-halt` is present        | Guardrail to prevent accidental host shutdown.                         |

### 2.4 Script bootstrap adjustments (examples)

- Update Snakepit.Examples.Bootstrap.run_example/2 to use :exit_mode or
  :stop_mode with safer defaults.
- Keep existing behavior for example scripts but align with the new API.

Rationale:

- Examples should reflect best practices and be robust under wrapper scripts.

## 3) Proposed changes (shutdown pipeline)

## 3.1 Authoritative Shutdown State Machine

The implementation and docs MUST converge on the following sequence
(diagrammable and testable):

1. Resolve `exit_mode` (precedence table) and `stop_mode`.
2. Start Snakepit if needed; record ownership (`owned?`) and capture `run_id`.
3. Optional: await pool readiness (`await_pool`).
4. Execute user function; capture outcome (`status` per Status Code Rules).
5. Shutdown orchestrator (single module, e.g., `Snakepit.Shutdown`):
   a. Emit telemetry `script.shutdown.start` with `run_id`, `exit_mode`,
      `stop_mode`, `owned?`, and `status`.
   b. Capture cleanup targets before stopping Snakepit (if needed), so cleanup
      does not depend on running registry processes.
   c. Conditional stop: stop Snakepit iff `stop_mode == :always` or
      (`stop_mode == :if_started` and `owned?`).
   d. Bounded cleanup: run RuntimeCleanup / run-id cleanup with timeout;
      idempotent by design.
   e. Conditional VM exit:

   * `:halt` -> hard halt (bypasses OTP shutdown callbacks; therefore cleanup
     MUST already be complete).
   * `:stop` -> cooperative VM shutdown (initiates OTP shutdown; caller blocks
     until exit).
   * `:none` -> return/raise to caller.

Notes:

* `System.halt/1` bypasses application stop callbacks and `terminate/2`. It
  must never be used as a substitute for cleanup.
* `System.stop/1` initiates a normal shutdown sequence; cleanup hooks may run,
  but the shutdown orchestrator must not rely on them.

- Clarify and document the shutdown sequence: run_as_script cleanup,
  Application.stop cleanup, and ApplicationCleanup emergency cleanup.
- Add telemetry events for exit mode selection and cleanup phases.
- Ensure cleanup operations are idempotent and safe under repeated calls.

Rationale:

- Improves observability and avoids ambiguity about which cleanup path ran.

## 4) Compatibility and migration

- Maintain :halt option with deprecation notes.
- Provide clear upgrade guidance in README and guides.
- Ensure existing scripts continue to run without changes.
