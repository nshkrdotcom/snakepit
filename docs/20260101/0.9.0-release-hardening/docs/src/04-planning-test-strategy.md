# Planning: Test Strategy (TDD)

This plan emphasizes TDD with explicit integration tests for exit semantics.
Most exit behavior cannot be tested within the same BEAM because System.halt
terminates the VM. Use external harnesses.

## 1) Unit tests (in-VM)

- Exit mode selection logic (pure functions):
  - :halt boolean vs :exit_mode precedence
  - env var SNAKEPIT_SCRIPT_EXIT parsing
  - default behavior when options are omitted

- Ownership tracking logic:
  - When Snakepit is already started, stop_mode :if_started should not stop.
  - When run_as_script starts Snakepit, stop_mode :if_started should stop.

## 2) Integration tests (external VM)

Use System.cmd/3 or Port.open to spawn a separate BEAM and assert behavior.

### 2.1 Exit behavior

- run_as_script with exit_mode :none should return and exit normally.
- exit_mode :halt should exit with the expected status code.
- exit_mode :stop should exit with expected status code.

### 2.2 Broken pipe simulation

- Run a script that writes to stdout, then closes the pipe early:
  - bash -c "mix run script.exs | head -1"
  - ensure the process exits and does not hang.

### 2.3 Wrapper commands

- Use timeout --foreground --preserve-status to verify no hangs:
  - timeout 5 mix run script.exs
  - expect exit in under the timeout.

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

