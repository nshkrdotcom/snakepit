# Agent Prompt: Snakepit Centralized Logging Refactor

## Objective

Refactor Snakepit's logging system to be:
1. **Completely centralized** - all logging (Elixir AND Python) goes through a unified system
2. **Silent by default** - no logs for expected/normal behavior
3. **Verbose only for exceptional cases** - warnings/errors only surface unexpected conditions
4. **Configurable** - users can easily enable debug/info logs when needed

## Decisions and Constraints (Updated)

- **Default** `log_level` is `:error`. Add `:none` to suppress everything.
- **Category filtering** only applies to `:debug` and `:info`. Warnings/errors bypass category filters; `:none` suppresses all logs.
- **GRPC_READY and health-check output** must not emit when `log_level = :none`. Because `GRPC_READY` is a protocol signal consumed by Elixir, move readiness signaling off stdout/stderr to a dedicated non-console channel so workers still start under default `:error` and `:none`.
- **Mix tasks output stays visible**. Treat `mix snakepit.doctor` and `mix snakepit.status` output as CLI output via `Mix.shell()`, not logging.
- **Python logging config is explicit**. Do NOT auto-configure on import. Entry points must call `configure_logging()` before any other imports that might log. Provide a `force` option for tests and reconfiguration.
- **If `SNAKEPIT_LOG_FORMAT` is documented, implement it** (json/text). Otherwise remove references and keep text-only formatting.
- **Telemetry stderr output is not logging**. Ensure telemetry only emits when telemetry is enabled and does not violate silent defaults.

## Current Version & Target

- **Current**: `0.8.0`
- **Target**: `0.8.1`
- **Changelog Date**: 2025-12-27

## Repository Location

```
/home/home/p/g/n/snakepit
```

## Phase 0: Protocol and Output Audit (NEW)

1. Identify ALL stdout/stderr outputs used for control/telemetry:
   - `GRPC_READY` signaling in Python worker start-up.
   - Any health-check prints.
   - Telemetry backends writing to stderr (e.g., `TELEMETRY:` lines).
2. Replace `GRPC_READY` stdout/stderr signaling with a non-console channel.
   - Acceptable options: ready file path (`SNAKEPIT_READY_FILE`), dedicated FD (`SNAKEPIT_READY_FD`), or other IPC.
   - Update `lib/snakepit/grpc_worker.ex` and tests that parse `GRPC_READY` to use the new channel.
3. Ensure health-check output is treated as logging (debug/info), not as a control signal.
4. Verify telemetry output stays opt-in and does not emit by default.

---

## Phase 1: Discovery (Use Multi-Agents)

### Task 1.1: Audit Elixir Logging

Scan ALL files in `lib/` for logging patterns. Search for:

```elixir
# Patterns to find:
Logger.debug
Logger.info
Logger.warning
Logger.error
Logger.notice
IO.puts
IO.warn
IO.inspect  # when used for logging
require Logger
alias Snakepit.Logger
Snakepit.Logger.
```

**Must-include hotspots (non-exhaustive):**
- `lib/snakepit.ex`
- `lib/snakepit/logger.ex`
- `lib/snakepit/grpc_worker.ex`
- `lib/snakepit/error.ex`
- `lib/snakepit/heartbeat_monitor.ex`
- `lib/snakepit/hardware.ex`
- `lib/snakepit/telemetry/*.ex`
- `lib/snakepit/pool/*.ex`
- `lib/snakepit/bridge/*.ex`
- `lib/snakepit/adapters/*.ex`
- `lib/snakepit/grpc/*.ex`
- `lib/snakepit/worker_profile/*.ex`
- `lib/mix/tasks/*.ex`
- `lib/snakepit/config.ex`

### Task 1.2: Audit Python Logging

Scan ALL files in `priv/python/` for logging patterns. Search for:

```python
# Patterns to find:
import logging
logging.
logger.
logger =
print(
sys.stdout
sys.stderr
logging.basicConfig
logging.getLogger
```

**Must-include hotspots (non-exhaustive):**
- `priv/python/grpc_server.py`
- `priv/python/grpc_server_threaded.py`
- `priv/python/snakepit_bridge/*.py`
- `priv/python/snakepit_bridge/adapters/*.py`
- `priv/python/snakepit_bridge/base_adapter_threaded.py`
- `priv/python/snakepit_bridge/thread_safety_checker.py`
- `priv/python/snakepit_bridge/telemetry/backends/stderr.py`

### Task 1.3: Document Current State

Create a table of ALL log points found:

| File | Line | Type | Level | Message Pattern | Should Keep? | Signal/Protocol? | Notes |
|------|------|------|-------|-----------------|--------------|------------------|-------|
| lib/snakepit.ex | 243 | IO.puts | info | "Script execution finished" | Conditional | No | Lifecycle |
| priv/python/grpc_server.py | 80 | print | info | "[health-check]..." | No | No | Startup noise |
| priv/python/grpc_server.py | 977 | logger.info | info | "GRPC_READY:{port}" | No (as log) | Yes | Move to control channel |

---

## Phase 2: Design the Unified Logging System

### 2.1 Elixir Side

The existing `Snakepit.Logger` module is a good foundation but needs:

1. **Default log level is `:error`** (silent-by-default); add `:none` for fully silent.
2. **Category filtering applies only to `:debug`/`:info`**. Warnings/errors bypass categories; `:none` suppresses all.
3. **Add structured logging metadata** (`category`, `worker_id`, `session_id`, `adapter`, etc.). Preserve existing metadata; do not stringify.
4. **Convert ALL IO.puts/IO.inspect to Snakepit.Logger** except for Mix tasks (use `Mix.shell()` output).
5. **Avoid ambiguous arity** in `Snakepit.Logger`:
   - Guard category-aware functions with a category whitelist so `debug(:grpc, "msg")` is unambiguous.
   - Provide backwards-compatible `debug(message, metadata \\ [])` etc for legacy call sites.

Proposed API enhancement:

```elixir
defmodule Snakepit.Logger do
  @moduledoc """
  Centralized, silent-by-default logging for Snakepit.

  ## Configuration

      # Silent (default) - only errors
      config :snakepit, log_level: :error

      # Warnings and errors
      config :snakepit, log_level: :warning

      # Verbose - info, warnings, errors
      config :snakepit, log_level: :info

      # Debug - everything
      config :snakepit, log_level: :debug

      # Completely silent (not even errors)
      config :snakepit, log_level: :none

  ## Categories

  Enable specific categories for targeted debugging:

      config :snakepit, log_categories: [:lifecycle, :grpc]
  """

  @type category :: :lifecycle | :pool | :grpc | :bridge | :worker | :startup | :shutdown
  @type level :: :debug | :info | :warning | :error | :none

  # Category-aware logging
  def debug(category, message, metadata \\ [])
  def info(category, message, metadata \\ [])
  def warning(category, message, metadata \\ [])
  def error(category, message, metadata \\ [])

  # Backwards compatible (defaults to :general category)
  def debug(message, metadata \\ [])
  def info(message, metadata \\ [])
  def warning(message, metadata \\ [])
  def error(message, metadata \\ [])
end
```

### 2.2 Python Side

Create a centralized Python logging configuration that:

1. **Respects environment variables** (e.g., `SNAKEPIT_LOG_LEVEL`).
2. **Defaults to ERROR**.
3. **Removes all hardcoded print() statements** (except non-log control signals, which must be moved off stdout/stderr).
4. **Uses a consistent format** (text or JSON if you keep `SNAKEPIT_LOG_FORMAT`).
5. **Does NOT auto-configure on import**. Call from entry points before any other imports that might log.

Create `priv/python/snakepit_bridge/logging_config.py`:

```python
"""
Centralized logging configuration for Snakepit Python components.

Environment variables:
    SNAKEPIT_LOG_LEVEL: debug, info, warning, error, none (default: error)
    SNAKEPIT_LOG_FORMAT: json, text (optional; implement or remove)
"""

import logging
import os
import sys


def configure_logging(force: bool = False) -> None:
    """Configure logging based on environment variables."""
    level_str = os.environ.get("SNAKEPIT_LOG_LEVEL", "error").lower()

    level_map = {
        "debug": logging.DEBUG,
        "info": logging.INFO,
        "warning": logging.WARNING,
        "error": logging.ERROR,
        "none": logging.CRITICAL + 1,
    }

    level = level_map.get(level_str, logging.ERROR)

    if level_str == "none":
        logging.disable(logging.CRITICAL)
    else:
        logging.disable(logging.NOTSET)

    logging.basicConfig(
        level=level,
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
        stream=sys.stderr,
        force=force,
    )

    # Suppress noisy third-party loggers
    logging.getLogger("grpc").setLevel(logging.WARNING)
    logging.getLogger("urllib3").setLevel(logging.WARNING)


def get_logger(name: str) -> logging.Logger:
    """Get a logger with the standard Snakepit namespace."""
    return logging.getLogger(f"snakepit.{name}")
```

- Update `priv/python/snakepit_bridge/__init__.py` to expose `configure_logging`/`get_logger`, **without calling** `configure_logging()`.
- Entry points that must call `configure_logging()` early:
  - `priv/python/grpc_server.py`
  - `priv/python/grpc_server_threaded.py`
  - Any CLI/script entry points (e.g., `thread_safety_checker.py`) that emit logs

### 2.3 Elixir-to-Python Log Level Propagation

When Snakepit starts Python workers, pass the log level:

```elixir
# In pool/worker_starter.ex or similar
defp python_env do
  log_level = Application.get_env(:snakepit, :log_level, :error)
  python_level = elixir_to_python_level(log_level)

  %{
    "SNAKEPIT_LOG_LEVEL" => python_level,
    # ... other env vars
  }
end

defp elixir_to_python_level(:debug), do: "debug"
defp elixir_to_python_level(:info), do: "info"
defp elixir_to_python_level(:warning), do: "warning"
defp elixir_to_python_level(:error), do: "error"
defp elixir_to_python_level(:none), do: "none"
defp elixir_to_python_level(_), do: "error"
```

### 2.4 Protocol/Control Signals (NEW)

- **Replace `GRPC_READY` stdout/stderr signaling** with a non-console channel (ready file or FD).
- Update Elixir to consume the new signal in `lib/snakepit/grpc_worker.ex`.
- Update tests and docs that mention `GRPC_READY` stdout output.
- Ensure health-check success is reported via exit code or explicit return value, not via stdout/stderr logs.

### 2.5 Mix Tasks and CLI Output

- `mix snakepit.doctor` and `mix snakepit.status` must remain visible by default.
- Use `Mix.shell().info/1` or `Mix.shell().error/1` for CLI output; do not route through `Snakepit.Logger`.

---

## Phase 3: Implementation (TDD)

### 3.1 Write Tests First

Create `test/snakepit/logger_test.exs`:

```elixir
defmodule Snakepit.LoggerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  describe "default behavior" do
    test "is silent for info level messages" do
      log = capture_log(fn ->
        Snakepit.Logger.info("This should not appear")
      end)

      assert log == ""
    end

    test "shows error level messages" do
      log = capture_log(fn ->
        Snakepit.Logger.error("This should appear")
      end)

      assert log =~ "This should appear"
    end
  end

  describe "with log_level: :none" do
    setup do
      Application.put_env(:snakepit, :log_level, :none)
      on_exit(fn -> Application.delete_env(:snakepit, :log_level) end)
      :ok
    end

    test "suppresses error messages" do
      log = capture_log(fn ->
        Snakepit.Logger.error("Nope")
      end)

      assert log == ""
    end
  end

  describe "categories" do
    setup do
      Application.put_env(:snakepit, :log_level, :info)
      Application.put_env(:snakepit, :log_categories, [:grpc])
      on_exit(fn ->
        Application.delete_env(:snakepit, :log_level)
        Application.delete_env(:snakepit, :log_categories)
      end)
      :ok
    end

    test "filters debug/info by category" do
      grpc_log = capture_log(fn ->
        Snakepit.Logger.info(:grpc, "gRPC message")
      end)

      pool_log = capture_log(fn ->
        Snakepit.Logger.info(:pool, "Pool message")
      end)

      assert grpc_log =~ "gRPC message"
      assert pool_log == ""
    end

    test "warnings/errors bypass category filters" do
      log = capture_log(fn ->
        Snakepit.Logger.warning(:pool, "Pool warning")
      end)

      assert log =~ "Pool warning"
    end
  end
end
```

Create Python tests in `priv/python/tests/test_logging_config.py`:

```python
import os
import logging


def test_default_level_is_error():
    os.environ.pop("SNAKEPIT_LOG_LEVEL", None)

    from snakepit_bridge import logging_config
    logging_config.configure_logging(force=True)

    logger = logging_config.get_logger("test")
    assert logger.isEnabledFor(logging.ERROR)
    assert not logger.isEnabledFor(logging.DEBUG)


def test_respects_env_var():
    os.environ["SNAKEPIT_LOG_LEVEL"] = "debug"

    from snakepit_bridge import logging_config
    logging_config.configure_logging(force=True)

    logger = logging_config.get_logger("test")
    assert logger.isEnabledFor(logging.DEBUG)


def test_none_disables_logging():
    os.environ["SNAKEPIT_LOG_LEVEL"] = "none"

    from snakepit_bridge import logging_config
    logging_config.configure_logging(force=True)

    logger = logging_config.get_logger("test")
    assert not logger.isEnabledFor(logging.ERROR)
```

Update gRPC readiness tests that currently parse `GRPC_READY` from stdout:
- `test/unit/grpc/grpc_worker_ephemeral_port_test.exs`
- `test/support/mock_grpc_server*.sh`

### 3.2 Implementation Order

1. Update `lib/snakepit/logger.ex` (defaults, categories, metadata, guards).
2. Implement the non-console readiness/control channel and update `lib/snakepit/grpc_worker.ex` + tests.
3. Create `priv/python/snakepit_bridge/logging_config.py` and update entry points to call it early.
4. Replace Python `print()` calls and direct `logging.basicConfig` usage.
5. Convert all Elixir `Logger.*` and `IO.*` logging to `Snakepit.Logger`.
6. Keep Mix task output visible via `Mix.shell()`.
7. Update docs/examples; bump version; update changelog.

---

## Phase 4: Verification Checklist

### Code Quality
- [ ] `mix compile --warnings-as-errors` passes
- [ ] `mix dialyzer` passes with no errors
- [ ] `mix credo --strict` passes (or document exceptions)
- [ ] `mix format --check-formatted` passes

### Tests
- [ ] `mix test` - all tests pass
- [ ] `pytest priv/python/` - all Python tests pass
- [ ] New logger tests exist and pass

### Behavior
- [ ] Running `mix run -e "Snakepit.run_as_script(fn -> :ok end)"` produces NO output
- [ ] Setting `config :snakepit, log_level: :debug` shows lifecycle messages
- [ ] `mix snakepit.doctor` and `mix snakepit.status` still emit CLI output
- [ ] Python worker startup produces no console output by default
- [ ] gRPC worker startup still succeeds without stdout `GRPC_READY`
- [ ] Errors still surface properly when `log_level` permits

### Version Bump
- [ ] `mix.exs` version updated to `0.8.1`
- [ ] `README.md` version references updated
- [ ] `CHANGELOG.md` has new entry for 2025-12-27

---

## Phase 5: CHANGELOG Entry

Add to `CHANGELOG.md`:

```markdown
## [0.8.1] - 2025-12-27

### Changed
- **BREAKING**: Default log level changed from `:warning` to `:error` for silent-by-default behavior
- Centralized all logging through `Snakepit.Logger` module
- Python logging now respects `SNAKEPIT_LOG_LEVEL` environment variable
- Replaced stdout `GRPC_READY` signaling with a non-console control channel
- Removed all hardcoded `IO.puts` and Python `print()` statements

### Added
- Category-based logging: `:lifecycle`, `:pool`, `:grpc`, `:bridge`, `:worker`, `:startup`, `:shutdown`
- `config :snakepit, log_categories: [...]` to enable specific categories
- `priv/python/snakepit_bridge/logging_config.py` for centralized Python logging

### Fixed
- Noisy startup messages no longer pollute console output
- Health-check messages suppressed by default
- gRPC server startup messages suppressed by default

### Migration Guide
If you relied on seeing startup logs, add to your config:
```elixir
config :snakepit, log_level: :info
```
```

---

## Documentation Updates (Required)

1. **Update ALL user-facing docs** to match the new logging behavior and readiness signaling:
   - `README.md`
   - `README_GRPC.md`
   - `README_TESTING.md`
   - `ARCHITECTURE.md`
   - `DIAGRAMS.md`
   - Relevant docs under `docs/` and `guides/`
2. **Determine if a new guide is needed** (e.g., `guides/logging.md` or `docs/logging.md`).
   - If a new guide is added, update `mix.exs` `docs` `extras` to include it.
   - If an existing guide already covers logging, update it instead of adding a new one.
3. **Update examples and benchmarks** under `examples/` and `bench/` if they rely on or mention stdout logs.

---

## Files to Modify (Complete List)

### Elixir
- All files under `lib/**/*.ex` that log or print (full scan required), including:
  - `lib/snakepit.ex`
  - `lib/snakepit/logger.ex`
  - `lib/snakepit/grpc_worker.ex`
  - `lib/snakepit/error.ex`
  - `lib/snakepit/heartbeat_monitor.ex`
  - `lib/snakepit/hardware.ex`
  - `lib/snakepit/telemetry/*.ex`
  - `lib/snakepit/pool/*.ex`
  - `lib/snakepit/bridge/*.ex`
  - `lib/snakepit/adapters/*.ex`
  - `lib/snakepit/grpc/*.ex`
  - `lib/snakepit/worker_profile/*.ex`
  - `lib/mix/tasks/*.ex`
  - `lib/snakepit/config.ex`
- Tests and helpers tied to readiness or logging:
  - `test/unit/grpc/grpc_worker_ephemeral_port_test.exs`
  - `test/support/mock_grpc_server.sh`
  - `test/support/mock_grpc_server_ephemeral.sh`

### Python
- All files under `priv/python/**/*.py` that log or print (full scan required), including:
  - `priv/python/grpc_server.py`
  - `priv/python/grpc_server_threaded.py`
  - `priv/python/snakepit_bridge/__init__.py`
  - `priv/python/snakepit_bridge/logging_config.py` (NEW)
  - `priv/python/snakepit_bridge/base_adapter.py`
  - `priv/python/snakepit_bridge/base_adapter_threaded.py`
  - `priv/python/snakepit_bridge/session_context.py`
  - `priv/python/snakepit_bridge/heartbeat.py`
  - `priv/python/snakepit_bridge/thread_safety_checker.py`
  - `priv/python/snakepit_bridge/telemetry/backends/stderr.py`
  - `priv/python/tests/test_logging_config.py` (NEW)

### Config/Meta
- `mix.exs` (version bump + docs extras if new guide)
- `README.md`
- `README_GRPC.md`
- `README_TESTING.md`
- `CHANGELOG.md`
- `config/config.exs` (document new defaults)
- Relevant docs in `docs/` and `guides/`
- Update examples under `examples/` and any load-test notes under `bench/`

---

## Success Criteria

1. **Silent by default**: Running any Snakepit operation produces zero console output unless an error occurs
2. **Configurable verbosity**: Setting `log_level: :debug` surfaces all internal messages
3. **GRPC_READY still works**: readiness is signaled without stdout/stderr logs
4. **No regressions**: All existing tests pass
5. **No dialyzer errors**: Type specs are correct
6. **Clean code**: No compiler warnings
7. **Documented**: Docs and changelog reflect the new logging and readiness behavior
