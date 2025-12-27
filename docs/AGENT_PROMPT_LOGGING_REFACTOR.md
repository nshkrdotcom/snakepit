# Agent Prompt: Snakepit Centralized Logging Refactor

## Objective

Refactor Snakepit's logging system to be:
1. **Completely centralized** - all logging (Elixir AND Python) goes through a unified system
2. **Silent by default** - no logs for expected/normal behavior
3. **Verbose only for exceptional cases** - warnings/errors only surface unexpected conditions
4. **Configurable** - users can easily enable debug/info logs when needed

## Current Version & Target

- **Current**: `0.8.0`
- **Target**: `0.8.1`
- **Changelog Date**: 2025-12-27

## Repository Location

```
/home/home/p/g/n/snakepit
```

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

**Files to read (comprehensive list):**
- `lib/snakepit.ex` - Main module (has IO.puts for lifecycle messages)
- `lib/snakepit/logger.ex` - Current centralized logger (ALREADY EXISTS)
- `lib/snakepit/application.ex` - Application startup
- `lib/snakepit/bootstrap.ex` - Bootstrap process
- `lib/snakepit/pool/*.ex` - All pool-related files
- `lib/snakepit/bridge/*.ex` - Bridge/session files
- `lib/snakepit/adapters/*.ex` - Adapter files
- `lib/snakepit/env_doctor.ex` - Environment diagnostics
- `lib/snakepit/telemetry/*.ex` - Telemetry handlers (may have logging)
- `lib/mix/tasks/*.ex` - Mix tasks

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

**Critical files to read:**
- `priv/python/grpc_server.py` - Main gRPC server (has hardcoded logging.INFO and print statements)
- `priv/python/snakepit_bridge/*.py` - All bridge modules
- `priv/python/snakepit_bridge/adapters/*.py` - Adapter implementations

### Task 1.3: Document Current State

Create a table of ALL log points found:

| File | Line | Type | Level | Message Pattern | Should Keep? | Notes |
|------|------|------|-------|-----------------|--------------|-------|
| lib/snakepit.ex | 243 | IO.puts | info | "Script execution finished" | Conditional | Lifecycle |
| priv/python/grpc_server.py | 80 | print | info | "[health-check]..." | No | Startup noise |

---

## Phase 2: Design the Unified Logging System

### 2.1 Elixir Side

The existing `Snakepit.Logger` module is a good foundation but needs:

1. **Change default from `:warning` to `:none` or `:error`**
2. **Add structured logging support** with consistent metadata
3. **Convert ALL IO.puts to use Snakepit.Logger**
4. **Add log categories** (e.g., :lifecycle, :pool, :grpc, :bridge)

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

1. **Respects an environment variable** (e.g., `SNAKEPIT_LOG_LEVEL`)
2. **Defaults to WARNING or ERROR**
3. **Removes all hardcoded print() statements**
4. **Uses structured logging format**

Create new file `priv/python/snakepit_bridge/logging_config.py`:

```python
"""
Centralized logging configuration for Snakepit Python components.

Environment variables:
    SNAKEPIT_LOG_LEVEL: debug, info, warning, error, none (default: error)
    SNAKEPIT_LOG_FORMAT: json, text (default: text)
"""

import logging
import os
import sys

def configure_logging():
    """Configure logging based on environment variables."""
    level_str = os.environ.get("SNAKEPIT_LOG_LEVEL", "error").upper()

    level_map = {
        "DEBUG": logging.DEBUG,
        "INFO": logging.INFO,
        "WARNING": logging.WARNING,
        "ERROR": logging.ERROR,
        "NONE": logging.CRITICAL + 1,  # Effectively disables all logging
    }

    level = level_map.get(level_str, logging.ERROR)

    # Configure root logger
    logging.basicConfig(
        level=level,
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
        stream=sys.stderr
    )

    # Suppress noisy third-party loggers
    logging.getLogger("grpc").setLevel(logging.WARNING)
    logging.getLogger("urllib3").setLevel(logging.WARNING)

def get_logger(name: str) -> logging.Logger:
    """Get a logger with the standard Snakepit configuration."""
    return logging.getLogger(f"snakepit.{name}")

# Auto-configure on import
configure_logging()
```

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

  describe "with log_level: :info" do
    setup do
      original = Application.get_env(:snakepit, :log_level)
      Application.put_env(:snakepit, :log_level, :info)
      on_exit(fn ->
        if original, do: Application.put_env(:snakepit, :log_level, original),
        else: Application.delete_env(:snakepit, :log_level)
      end)
      :ok
    end

    test "shows info level messages" do
      log = capture_log(fn ->
        Snakepit.Logger.info("This should appear")
      end)

      assert log =~ "This should appear"
    end
  end

  describe "categories" do
    test "respects category filtering" do
      Application.put_env(:snakepit, :log_level, :info)
      Application.put_env(:snakepit, :log_categories, [:grpc])

      grpc_log = capture_log(fn ->
        Snakepit.Logger.info(:grpc, "gRPC message")
      end)

      pool_log = capture_log(fn ->
        Snakepit.Logger.info(:pool, "Pool message")
      end)

      assert grpc_log =~ "gRPC message"
      assert pool_log == ""
    after
      Application.delete_env(:snakepit, :log_level)
      Application.delete_env(:snakepit, :log_categories)
    end
  end
end
```

Create Python tests in `priv/python/tests/test_logging_config.py`:

```python
import os
import pytest
import logging

def test_default_level_is_error():
    # Clear any existing env var
    os.environ.pop("SNAKEPIT_LOG_LEVEL", None)

    # Re-import to reset
    from snakepit_bridge import logging_config
    logging_config.configure_logging()

    logger = logging_config.get_logger("test")
    assert logger.getEffectiveLevel() >= logging.ERROR

def test_respects_env_var():
    os.environ["SNAKEPIT_LOG_LEVEL"] = "debug"

    from snakepit_bridge import logging_config
    logging_config.configure_logging()

    logger = logging_config.get_logger("test")
    assert logger.getEffectiveLevel() == logging.DEBUG
```

### 3.2 Implementation Order

1. **Update `lib/snakepit/logger.ex`**
   - Change default level from `:warning` to `:error`
   - Add category support
   - Add structured metadata

2. **Create `priv/python/snakepit_bridge/logging_config.py`**
   - Centralized Python logging
   - Environment variable support

3. **Update `priv/python/grpc_server.py`**
   - Remove `logging.basicConfig` (use logging_config instead)
   - Replace ALL `print()` with `logger.debug()` or `logger.info()`
   - Change default level to ERROR

4. **Update `lib/snakepit.ex`**
   - Replace ALL `IO.puts("[Snakepit]...")` with `Snakepit.Logger.debug(:lifecycle, ...)`

5. **Update `lib/snakepit/env_doctor.ex`**
   - Replace print-style output with Logger calls

6. **Update all other files**
   - Convert `require Logger` + `Logger.info` to `alias Snakepit.Logger` + `Snakepit.Logger.info`

7. **Update `lib/snakepit/adapters/grpc_python.ex`**
   - Pass `SNAKEPIT_LOG_LEVEL` environment variable to Python workers

---

## Phase 4: Verification Checklist

Before marking complete, verify:

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
- [ ] Python worker startup produces no console output by default
- [ ] Errors still surface properly

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

## Files to Modify (Complete List)

### Elixir Files
```
lib/snakepit.ex
lib/snakepit/logger.ex
lib/snakepit/application.ex
lib/snakepit/bootstrap.ex
lib/snakepit/pool/pool.ex
lib/snakepit/pool/worker_supervisor.ex
lib/snakepit/pool/worker_starter.ex
lib/snakepit/adapters/grpc_python.ex
lib/snakepit/env_doctor.ex
lib/snakepit/telemetry/handlers/logger.ex
lib/mix/tasks/snakepit.doctor.ex
lib/mix/tasks/snakepit.status.ex
```

### Python Files
```
priv/python/grpc_server.py
priv/python/snakepit_bridge/__init__.py (add logging_config import)
priv/python/snakepit_bridge/logging_config.py (NEW)
priv/python/snakepit_bridge/base_adapter.py
priv/python/snakepit_bridge/session_context.py
priv/python/snakepit_bridge/heartbeat.py
```

### Config/Meta Files
```
mix.exs (version bump)
README.md (version reference)
CHANGELOG.md (new entry)
config/config.exs (document new defaults)
```

---

## Success Criteria

1. **Silent by default**: Running any Snakepit operation produces zero console output unless an error occurs
2. **Configurable verbosity**: Setting `log_level: :debug` surfaces all internal messages
3. **No regressions**: All existing tests pass
4. **No dialyzer errors**: Type specs are correct
5. **Clean code**: No compiler warnings
6. **Documented**: CHANGELOG reflects changes
