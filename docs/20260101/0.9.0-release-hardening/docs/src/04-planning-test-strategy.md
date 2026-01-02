# Planning: Test Strategy (TDD)

This plan emphasizes TDD with explicit integration tests for exit semantics.
Most exit behavior cannot be tested within the same BEAM because System.halt
terminates the VM. Use external harnesses.

## 0) Portability policy for integration tests (authoritative)

Integration tests MUST be runnable on Linux and macOS CI without assuming GNU
coreutils.

* Do not require `timeout --foreground` or GNU-only flags. When a watchdog is
  needed, prefer an Elixir-level timeout around `System.cmd/3` (e.g.,
  `Task.yield/2` + `Task.shutdown/2`).
* Prefer pure-Elixir broken-pipe simulation (spawn child VM with stdout piped
  to the parent, read one line, then close the pipe) over shell pipelines.
* Any test that depends on optional external tools must be tagged and skipped
  when the tool is missing (e.g., `:requires_timeout_cmd`).

## 1) Unit tests (in-VM)

- Exit mode selection logic (pure functions):
  - :halt boolean vs :exit_mode precedence
  - env var SNAKEPIT_SCRIPT_EXIT parsing
  - default behavior when options are omitted
  - SNAKEPIT_SCRIPT_EXIT parsing:
    - trims whitespace, case-insensitive
    - empty string treated as unset
    - invalid values ignored (and produce a pre-shutdown warning log)
  - Full precedence chain:
    - :exit_mode > legacy :halt option > SNAKEPIT_SCRIPT_EXIT >
      legacy SNAKEPIT_SCRIPT_HALT > default

- Ownership tracking logic:
  - When Snakepit is already started, stop_mode :if_started should not stop.
  - When run_as_script starts Snakepit, stop_mode :if_started should stop.

## 2) Integration tests (external VM)

Use System.cmd/3 or Port.open to spawn a separate BEAM and assert behavior.

### 2.1 Exit behavior

- run_as_script with exit_mode :none should return and exit normally.
- exit_mode :halt should exit with the expected status code.
- exit_mode :stop should exit with expected status code.
- exit_mode :auto behavior:
  - With --no-halt: VM exits (equivalent to :stop) with status per Status Code Rules.
  - Without --no-halt: no forced VM exit (equivalent to :none).
  - Embedded (Snakepit already started): :auto resolves to :none even if
    --no-halt is present.

### 2.2 Broken pipe simulation (portable)

Preferred (pure Elixir):

* Spawn the script VM with stdout piped to a parent Port, read one line, then
  close the pipe to trigger EPIPE in the child. Assert the child exits and does
  not hang.

Acceptable fallback (shell pipeline):

* `sh -c 'mix run script.exs | head -1'`
* Gate this test if `head` is unavailable.

### 2.3 Hang detection / watchdog (portable)

* Use an Elixir-level watchdog (Task timeout) to ensure the spawned VM exits
  within N seconds.
* Optional: if `timeout` (GNU) or `gtimeout` is available, run a secondary
  validation under the external wrapper; gate by tool presence.

### 2.4 Ownership boundaries

- Spawn an app that starts Snakepit, then runs a script calling
  run_as_script with stop_mode :if_started. Validate Snakepit stays running.

## 3) Test layout

- test/snakepit/script_exit_test.exs (unit-level option selection tests)
- test/snakepit/script_exit_integration_test.exs (external VM integration)

## 4) Test data and helpers

- Create test scripts under test/support/scripts/
- Provide helper to run mix or elixir with env vars.
- Ensure integration tests are tagged (e.g., :integration) and skipped by
  default in CI if necessary.
