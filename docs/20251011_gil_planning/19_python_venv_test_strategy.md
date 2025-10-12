# Python Virtual Environment Test Strategy

**Purpose**: Enable testing both GIL and no-GIL scenarios
**Date**: 2025-10-11

---

## Design Goals

1. **Isolate Python versions** - Test with 3.12 (GIL) and 3.13 (no-GIL) independently
2. **No system pollution** - Use venvs, don't modify system Python
3. **Test selectability** - Tag tests by Python version requirement
4. **CI/CD ready** - Can run in GitHub Actions
5. **Developer friendly** - Simple setup script

---

## Architecture

```
snakepit/
├── .venv/                    # Default venv (Python 3.12.3, existing)
├── .venv-py313/              # Python 3.13 venv (no-GIL, NEW)
├── test/
│   ├── support/
│   │   ├── python_env.ex     # Python environment helper
│   │   └── test_config.ex    # Test configuration helper
│   └── snakepit/
│       └── gil_scenarios/    # Tests requiring specific Python
│           ├── python312_gil_test.exs
│           ├── python313_nogil_test.exs
│           └── multi_pool_dual_mode_test.exs
└── scripts/
    └── setup_test_pythons.sh # Setup script
```

---

## Implementation Plan

### 1. Setup Script (`scripts/setup_test_pythons.sh`)

```bash
#!/bin/bash
# Setup Python environments for testing

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

echo "Setting up Python test environments..."

# Python 3.12 (GIL) - use existing or create
if [ ! -d ".venv" ]; then
    echo "Creating Python 3.12 venv..."
    python3.12 -m venv .venv
    .venv/bin/pip install --upgrade pip
    .venv/bin/pip install -r priv/python/requirements.txt
else
    echo "✓ Python 3.12 venv exists"
fi

# Python 3.13 (no-GIL) - create new
if [ ! -d ".venv-py313" ]; then
    echo "Creating Python 3.13 venv..."

    # Check if python3.13 exists
    if command -v python3.13 &> /dev/null; then
        python3.13 -m venv .venv-py313
        .venv-py313/bin/pip install --upgrade pip
        .venv-py313/bin/pip install -r priv/python/requirements.txt
        echo "✓ Python 3.13 venv created"
    else
        echo "⚠️  python3.13 not found. Install with: uv python install 3.13"
        echo "   Or: brew install python@3.13 (macOS)"
        echo "   Thread profile tests will be skipped"
    fi
else
    echo "✓ Python 3.13 venv exists"
fi

# Verify installations
echo ""
echo "Python environments:"
if [ -d ".venv" ]; then
    .venv/bin/python --version
fi
if [ -d ".venv-py313" ]; then
    .venv-py313/bin/python --version
    # Check if free-threading is available
    .venv-py313/bin/python -c "import sys; print('GIL:', 'disabled' if hasattr(sys, '_is_gil_enabled') and not sys._is_gil_enabled() else 'enabled')"
fi

echo ""
echo "Setup complete!"
```

### 2. Test Helper (`test/support/python_env.ex`)

```elixir
defmodule Snakepit.Test.PythonEnv do
  @moduledoc """
  Helper for managing Python environments in tests.

  Supports:
  - Python 3.12 (GIL) via .venv
  - Python 3.13 (no-GIL) via .venv-py313
  - Automatic skipping if environment unavailable
  """

  @py312_path ".venv/bin/python3"
  @py313_path ".venv-py313/bin/python3"

  def python_312_available? do
    File.exists?(@py312_path)
  end

  def python_313_available? do
    File.exists?(@py313_path)
  end

  def python_312_path, do: Path.expand(@py312_path)
  def python_313_path, do: Path.expand(@py313_path)

  def skip_unless_python_312(context) do
    if python_312_available?() do
      Map.put(context, :python_path, python_312_path())
    else
      {:skip, "Python 3.12 venv not available"}
    end
  end

  def skip_unless_python_313(context) do
    if python_313_available?() do
      Map.put(context, :python_path, python_313_path())
    else
      {:skip, "Python 3.13 venv not available (run: scripts/setup_test_pythons.sh)"}
    end
  end

  def configure_for_python(python_path) do
    # Set environment so Snakepit uses specific Python
    System.put_env("SNAKEPIT_PYTHON", python_path)
    Application.put_env(:snakepit, :python_executable, python_path)
  end
end
```

### 3. Test Tags Strategy

```elixir
# Tag tests by Python requirement
@tag :python312      # Requires Python 3.12 (GIL)
@tag :python313      # Requires Python 3.13 (no-GIL)
@tag :multi_pool     # Tests multi-pool features
@tag :lifecycle      # Tests recycling
@tag :concurrent     # Tests thread concurrency

# Run specific tests:
# mix test --only python312
# mix test --only python313
# mix test --only multi_pool
# mix test --exclude python313  # Skip if no Python 3.13
```

---

## Test Organization

### Test File Structure

```
test/snakepit/
├── unit/                              # Fast, no workers
│   ├── config_test.exs
│   ├── python_version_test.exs
│   └── compatibility_test.exs
│
├── integration/                       # Requires workers
│   ├── single_pool_test.exs          # Current v0.5.x behavior
│   ├── multi_pool_test.exs           # NEW: 2+ pools
│   ├── pool_routing_test.exs         # NEW: Named pool execution
│   └── lifecycle_test.exs            # NEW: Recycling per pool
│
└── gil_scenarios/                     # Python version specific
    ├── python312_gil_test.exs        # @tag :python312
    ├── python313_nogil_test.exs      # @tag :python313
    └── thread_concurrency_test.exs   # @tag :python313, :concurrent
```

---

## Test Matrix

| Test Scenario | Python 3.12 | Python 3.13 | Tags |
|---------------|-------------|-------------|------|
| Config parsing | ✅ | ✅ | (none) |
| Single pool (legacy) | ✅ | ✅ | :integration |
| Multi-pool startup | ✅ | ✅ | :multi_pool |
| Pool routing | ✅ | ✅ | :multi_pool |
| Process profile | ✅ | ✅ | :integration |
| Thread profile startup | ✅ | ✅ | :python313 |
| Thread concurrency | ❌ | ✅ | :python313, :concurrent |
| GIL-free performance | ❌ | ✅ | :python313 |

---

## Setup Instructions

### 1. Install Python 3.13
```bash
# Using uv
uv python install 3.13

# Or system package manager
brew install python@3.13  # macOS
apt install python3.13    # Ubuntu
```

### 2. Run setup script
```bash
chmod +x scripts/setup_test_pythons.sh
./scripts/setup_test_pythons.sh
```

### 3. Verify
```bash
.venv/bin/python --version        # Should show 3.12.x
.venv-py313/bin/python --version  # Should show 3.13.x
```

---

## Test Execution Plan

### Phase 1: Unit tests (no Python needed)
```bash
mix test test/snakepit/unit/
# All should pass
```

### Phase 2: Integration with Python 3.12
```bash
SNAKEPIT_PYTHON=.venv/bin/python3 mix test --only integration
# Tests single-pool, process profile
```

### Phase 3: Multi-pool tests
```bash
mix test --only multi_pool
# WILL FAIL - multi-pool not implemented yet
```

### Phase 4: Python 3.13 tests
```bash
SNAKEPIT_PYTHON=.venv-py313/bin/python3 mix test --only python313
# WILL FAIL - thread profile execution not fully tested
```

### Phase 5: Concurrent tests
```bash
SNAKEPIT_PYTHON=.venv-py313/bin/python3 mix test --only concurrent
# WILL FAIL - concurrent request handling not validated
```

---

## Next Steps

1. Create `scripts/setup_test_pythons.sh`
2. Create `test/support/python_env.ex`
3. Reorganize existing tests into unit/ and integration/
4. Write NEW tests for:
   - Multi-pool startup (WILL FAIL)
   - Pool routing (WILL FAIL)
   - Per-pool recycling (WILL FAIL)
   - Thread profile with Python 3.13 (WILL FAIL)
   - Concurrent requests (WILL FAIL)
5. Run tests, watch them fail
6. Implement features to make tests pass
7. Achieve 100% on ALL scenarios

**Estimated effort**: 2 days (1 day tests, 1 day implementation)
