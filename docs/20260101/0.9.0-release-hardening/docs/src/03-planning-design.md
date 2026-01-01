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
  - :auto - choose :halt only when explicitly requested via env var or
    when a known script wrapper requires it.

Compatibility:

- Keep :halt boolean for backward compatibility.
- If :halt is true and :exit_mode is not set, treat as :halt.
- If :exit_mode is set, ignore :halt to avoid ambiguity.
- Continue honoring SNAKEPIT_SCRIPT_HALT but deprecate in favor of
  SNAKEPIT_SCRIPT_EXIT (string: none|halt|stop|auto).

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

### 2.4 Script bootstrap adjustments (examples)

- Update Snakepit.Examples.Bootstrap.run_example/2 to use :exit_mode or
  :stop_mode with safer defaults.
- Keep existing behavior for example scripts but align with the new API.

Rationale:

- Examples should reflect best practices and be robust under wrapper scripts.

## 3) Proposed changes (shutdown pipeline)

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

