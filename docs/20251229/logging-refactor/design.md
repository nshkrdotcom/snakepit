# Process-Aware Logging Design

## Problem Statement

The current `Snakepit.Logger` module uses global `Application.get_env(:snakepit, :log_level)` for configuration. This causes race conditions in async tests when multiple tests modify the log level concurrently.

### Evidence

Test `test falls back with warning when zero-copy is disabled` in `zero_copy_test.exs:29` fails intermittently because:

1. Test A sets `:log_level` to `:warning`
2. Test B (running concurrently) sets `:log_level` to `:none` or `:info`
3. Test A's warning log is filtered out based on Test B's config
4. Test A fails because expected log message is missing

Captured logs showed messages from other tests bleeding into the capture:
```
category=grpc [info] grpc message      <- from logger_test.exs
category=general [error] this should appear  <- from logger_test.exs
category=pool [warning] pool warning   <- from logger_test.exs
```

## Solution: Process-Aware Log Level Resolution

### Key Insight

Elixir's `Logger` module already supports per-process log levels via:
- `Logger.put_process_level(pid, level)` - set level for a process
- `Logger.get_process_level(pid)` - get level for a process

Supertester 0.4.0's `LoggerIsolation` module uses this exact mechanism.

### Design

Refactor `Snakepit.Logger` to use a **priority-based log level resolution**:

1. **Process-local override** (highest priority) - via process dictionary
2. **Elixir Logger process level** - via `Logger.get_process_level/1`
3. **Application config** (lowest priority) - via `Application.get_env/3`

```
┌─────────────────────────────────────────────────────────────┐
│                    Log Level Resolution                      │
├─────────────────────────────────────────────────────────────┤
│  1. Process dictionary :snakepit_log_level_override         │
│     ↓ (if nil)                                              │
│  2. Logger.get_process_level(self())                        │
│     ↓ (if nil)                                              │
│  3. Application.get_env(:snakepit, :log_level, :error)      │
└─────────────────────────────────────────────────────────────┘
```

### API Design

#### New Functions in `Snakepit.Logger`

```elixir
# Set log level for current process only (test-friendly)
@spec set_process_level(level()) :: :ok
def set_process_level(level)

# Get effective log level for current process
@spec get_process_level() :: level()
def get_process_level()

# Clear process-level override, revert to global
@spec clear_process_level() :: :ok
def clear_process_level()

# Execute function with temporary log level
@spec with_level(level(), (-> result)) :: result when result: term()
def with_level(level, fun)
```

#### Test Helpers

New module `Snakepit.Logger.TestHelper` (only compiled for :test):

```elixir
# Isolate log level for the duration of a test
def setup_log_isolation do
  original = Snakepit.Logger.get_process_level()

  on_exit(fn ->
    if original do
      Snakepit.Logger.set_process_level(original)
    else
      Snakepit.Logger.clear_process_level()
    end
  end)

  :ok
end

# Capture logs at specific level without affecting other tests
def capture_at_level(level, fun) do
  Snakepit.Logger.with_level(level, fn ->
    ExUnit.CaptureLog.capture_log(fun)
  end)
end
```

### Category Resolution

Categories (`:log_categories`) remain global since they don't typically cause race conditions. However, we could add process-local override if needed in the future.

## Implementation Plan

### Phase 1: Core Logger Refactor

1. Add process dictionary key `:snakepit_log_level_override`
2. Modify `should_log_level?/1` to check process-local first
3. Add `set_process_level/1`, `get_process_level/0`, `clear_process_level/0`
4. Add `with_level/2` for scoped overrides

### Phase 2: Test Migration

1. Create `Snakepit.Logger.TestHelper` module
2. Update all tests that modify `:log_level` to use new API
3. Remove `Application.put_env(:snakepit, :log_level, ...)` from tests
4. Keep `async: true` in all migrated tests

### Phase 3: Verification

1. Run full test suite multiple times to verify no flakiness
2. Run dialyzer for type safety
3. Run credo for code quality

## Affected Files

### Modified
- `lib/snakepit/logger.ex` - Core logging logic
- `test/snakepit/logger_test.exs` - Logger tests
- `test/snakepit/zero_copy_test.exs` - Zero copy tests
- `test/unit/pool/pool_registry_lookup_test.exs` - Pool registry tests
- `test/unit/pool/worker_supervisor_test.exs` - Worker supervisor tests
- `test/unit/logger/logger_defaults_test.exs` - Logger defaults tests
- `test/snakepit/pool/worker_lifecycle_test.exs` - Worker lifecycle tests

### New
- `test/support/logger_test_helper.ex` - Test isolation helpers (in test/support to avoid dialyzer issues)
- `docs/20251229/logging-refactor/design.md` - This document

## Backward Compatibility

- `Application.get_env(:snakepit, :log_level)` still works for production
- Existing tests continue to work (but should be migrated)
- No breaking changes to public API

## Testing Strategy

1. Unit tests for new Logger functions
2. Integration tests verifying no log pollution between async tests
3. Regression tests for existing behavior
4. Run test suite 5+ times to verify no flakiness

## Version

This change will be released as version 0.8.2.
