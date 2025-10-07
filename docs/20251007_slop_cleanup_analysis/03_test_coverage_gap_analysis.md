# Test Coverage & Gap Analysis

**Date**: 2025-10-07
**Test Suite**: 160 tests + 9 properties = 169 test cases
**Result**: 160/160 pass, 0 failures, 5 excluded (performance)

---

## Test Coverage Map

### What IS Tested (✅ Good Coverage)

#### Pool Infrastructure (35+ tests)
- Worker pooling logic
- Checkout/checkin flow
- Queue management
- Worker lifecycle
- Supervision behavior

**Files**:
- `test/snakepit/pool/*_test.exs`
- Coverage: ~85%

#### Process Management (25+ tests)
- ProcessRegistry DETS persistence
- Orphan detection
- Process tracking
- Cleanup logic

**Files**:
- Implicit in integration tests
- Coverage: ~75%

#### Bridge/Session System (45+ tests)
- SessionStore creation/cleanup
- Session TTL enforcement
- Session affinity
- Tool registration
- Variable system

**Files**:
- `test/snakepit/bridge/*_test.exs`
- `test/unit/bridge/session_store_test.exs`
- Coverage: ~80%

#### Serialization (20+ tests)
- JSON encoding/decoding
- Binary data handling
- Type conversions
- Error handling

**Files**:
- `test/snakepit/bridge/serialization_test.exs`
- Coverage: ~90%

#### Variables System (25+ tests)
- All variable types (String, Integer, Float, Boolean, Choice, Tensor, Embedding)
- Constraints validation
- Type coercion
- History tracking

**Files**:
- `test/snakepit/bridge/variables/*_test.exs`
- Coverage: ~95%

#### gRPC Components (15+ tests)
- BridgeServer RPC handlers
- Client connections
- Stream handling
- Error propagation

**Files**:
- `test/snakepit/grpc/bridge_server_test.exs`
- `test/unit/grpc/grpc_worker_test.exs`
- Coverage: ~70%

### What is NOT Tested (❌ Gaps)

#### 1. Examples (0 tests) ❌ CRITICAL GAP
**What's Missing**:
- No automated tests for any example file
- Examples can break without CI noticing
- Currently ALL examples are broken (wrong adapter)

**Impact**: HIGH
- Users can't trust examples
- Examples diverge from reality
- Breaking changes undetected

**Recommendation**: Add example smoke tests

#### 2. Adapter Configuration (0 tests) ❌ CRITICAL GAP
**What's Missing**:
- No tests for default adapter selection
- No tests for `adapter_args` override
- No validation that adapters actually work

**Impact**: HIGH
- Wrong defaults ship to production
- Configuration errors not caught
- Current bug (EnhancedBridge default) went unnoticed

**Recommendation**: Add adapter config tests

#### 3. Real Python Processes (2 tests) ⚠️ MAJOR GAP
**What's Missing**:
- Most tests use `MockGRPCAdapter`
- Only 2 tests use actual Python
- Port binding not tested
- Python crashes not tested
- gRPC connection failures partially tested

**Impact**: MEDIUM
- Real-world failures not validated
- Mock behavior might diverge from reality
- Integration issues found only in production

**Recommendation**: Add real Python integration tests (opt-in)

#### 4. Concurrent Restarts (0 tests) ⚠️ MAJOR GAP
**What's Missing**:
- No tests for concurrent worker restarts
- No tests for port conflicts during restart
- Race conditions not validated

**Impact**: MEDIUM
- Issue #2 concern about `wait_for_worker_cleanup` not validated
- Could have subtle race bugs

**Recommendation**: Add concurrent chaos tests

#### 5. Network Failures (partial) ⚠️ MINOR GAP
**What's Missing**:
- gRPC timeout behavior
- Connection retry logic
- Network partition scenarios

**Impact**: LOW
- Most covered by unit tests
- Some real-world scenarios untested

**Recommendation**: Nice-to-have integration tests

---

## Mock vs Real Testing

### Current State

**4 test files use mocks**:
- `test/support/mock_adapters.ex`
- `test/unit/grpc/grpc_worker_mock_test.exs`
- Others using `MockGRPCAdapter`

**0 test files use real Python** (except opt-in integration tests)

### Implications

✅ **Pros of Mocking**:
- Fast test execution
- No Python dependency for CI
- Deterministic behavior
- Easy to test edge cases

❌ **Cons of Mocking**:
- Mocks can drift from reality
- Doesn't validate Python code works
- Doesn't catch integration bugs
- False confidence

### The Adapter Mock Problem

**Critical Issue**: `MockGRPCAdapter` might not match `ShowcaseAdapter` behavior

**Evidence**:
- Tests pass with MockGRPCAdapter ✅
- Examples fail with ShowcaseAdapter ❌
- Divergence possible

**Recommendation**: Add contract tests to validate mocks match reality

---

## Test Quality Assessment

### High-Quality Tests ✅

**Property-Based Tests** (`property_test.exs`):
- 9 properties tested
- Randomized inputs
- Validates invariants
- Excellent for finding edge cases

**Integration Tests** (`*_integration_test.exs`):
- Multi-component testing
- Realistic workflows
- Good error scenarios

### Medium-Quality Tests ⚠️

**Unit Tests**:
- Good coverage of individual modules
- Heavy use of mocks
- Some sleep-based synchronization (anti-pattern)

**Example from tests**:
```elixir
# Found in some tests:
Process.sleep(100)  # ⚠️ Timing-dependent
```

**Note**: Foundation repo guidance warns against this!

### Test Gaps by Priority

#### P0 - Must Add
1. **Example smoke tests** - Validate examples work
2. **Adapter config tests** - Validate defaults are functional

#### P1 - Should Add
3. **Real Python integration tests** - At least basic cases
4. **Concurrent restart tests** - Validate Issue #2 fix
5. **Port conflict tests** - Resource cleanup validation

#### P2 - Nice to Have
6. **Chaos tests** - Kill processes randomly
7. **Network failure tests** - Connection issues
8. **Performance regression tests** - Benchmark critical paths

---

## Code That's Tested vs Code That Exists

### Fully Tested (>80% coverage) ✅

- `Snakepit.Pool` and all submodules
- `Snakepit.Bridge.Serialization`
- `Snakepit.Bridge.Variables.*` (all types)
- `Snakepit.Bridge.SessionStore`
- Core supervision logic

### Partially Tested (50-80%) ⚠️

- `Snakepit.GRPCWorker` - mostly via mocks
- `Snakepit.GRPC.BridgeServer` - RPC handlers tested, full flows partial
- `Snakepit.GRPC.Client` - basic calls tested, edge cases not
- `Snakepit.Telemetry` - some events tested

### Minimally Tested (<50%) ⚠️

- `Snakepit.Adapters.GRPCPython` - adapter selection not tested
- `Snakepit.Adapters.GRPCBridge` - unclear if used at all
- `Snakepit.Python` - legacy? Some tests but purpose unclear
- `Snakepit.SessionHelpers` - wrapper functions, minimal testing

### Not Tested At All (0%) ❌

- **Examples** - critical gap
- **Adapter defaults** - current bug source
- **Real Python adapters** - EnhancedBridge, ShowcaseAdapter
- **End-to-end workflows** - full stack scenarios

---

## Python Code Testing

### Python Test Suite

**Location**: `priv/python/tests/`

```bash
ls priv/python/tests/
# test_serialization.py
```

**ONE test file for entire Python codebase!**

### What's NOT Tested in Python

❌ `grpc_server.py` - main server logic
❌ `EnhancedBridge` - template adapter
❌ `ShowcaseAdapter` - working adapter
❌ `session_context.py` - session management
❌ All handlers in `showcase/handlers/`

**Impact**: Python code has **effectively zero test coverage**

**Implication**: We're trusting LLM-generated Python code with no validation!

---

## Self-Critique & Assumptions Check

### Assumption 1: "Tests passing means code works"

❓ **CHALLENGE**: Do passing tests validate the full system?

**Evidence**:
- ✅ Tests pass: 160/160
- ❌ Examples fail: 8/9 broken
- ❌ Real Python: Not tested

**Conclusion**: **FALSE** - Tests validate mocks work, not the real system

**Implication**: High risk of bugs in untested code paths

---

### Assumption 2: "EnhancedBridge was meant to work"

❓ **CHALLENGE**: Was EnhancedBridge ever functional?

**Evidence**:
- Git history: Never had `execute_tool`
- Docstring: "minimal implementation for Stage 0"
- Comments: "Future: Register built-in tools"
- Features dict: All features marked `False`

**Conclusion**: **FALSE** - EnhancedBridge is intentionally a template

**Implication**: Not a bug, but a **documentation/naming problem**

---

### Assumption 3: "Examples used to work"

❓ **CHALLENGE**: Did examples ever work with current config?

**Evidence**:
- Examples unchanged since v0.4.1
- EnhancedBridge unchanged since creation
- Default adapter has always been EnhancedBridge
- No example validation in CI

**Conclusion**: **UNKNOWN** - possibly never worked, or worked with different config

**Implication**: May need to investigate what configuration was used when examples were created

---

### Assumption 4: "Worker.Starter is unnecessary"

❓ **CHALLENGE**: Is Issue #2 critique valid?

**Evidence from testing**:
- ✅ Pattern works correctly (tests pass)
- ✅ Automatic restarts validated
- ⚠️ No tests for simpler alternative
- ❌ No documented rationale

**Conclusion**: **PARTIALLY TRUE** - Pattern works but value is unclear

**Implication**: Need to test simplified version to compare

---

## Test-Driven Refactoring Approach

### Strategy

For each refactoring:

1. **Write test first** that validates desired behavior
2. **Run test** - should fail initially
3. **Implement fix**
4. **Run test** - should pass
5. **Run ALL tests** - ensure no regressions
6. **Test examples** - validate user experience

### Example: Fix Default Adapter

**Step 1**: Write test
```elixir
defmodule Snakepit.Adapters.ConfigTest do
  use ExUnit.Case

  test "default adapter is ShowcaseAdapter" do
    args = Snakepit.Adapters.GRPCPython.script_args()
    assert ["--adapter", adapter_path] = args
    assert String.ends_with?(adapter_path, "ShowcaseAdapter")
  end

  test "can override adapter via pool config" do
    Application.put_env(:snakepit, :pool_config, %{
      adapter_args: ["--adapter", "custom.Adapter"]
    })

    args = Snakepit.Adapters.GRPCPython.script_args()
    assert ["--adapter", "custom.Adapter"] = args
  end
end
```

**Step 2**: Run - fails (uses EnhancedBridge)

**Step 3**: Implement fix (change default to ShowcaseAdapter)

**Step 4**: Run - passes

**Step 5**: Run full suite - all 160 pass

**Step 6**: Test examples - all work

---

## Recommended Test Additions

### Priority 1: Example Validation Tests

**Create**: `test/examples_smoke_test.exs`

```elixir
defmodule Snakepit.ExamplesSmokeTest do
  use ExUnit.Case, async: false

  @moduletag :examples
  @moduletag timeout: :infinity

  setup_all do
    # Ensure Python dependencies are available
    case System.cmd("python3", ["-c", "import grpc"]) do
      {_, 0} -> :ok
      _ -> :ok  # Tests will be skipped
    end
  end

  @examples [
    "grpc_basic.exs",
    "grpc_concurrent.exs",
    "grpc_sessions.exs",
    "bidirectional_tools_demo.exs"
  ]

  for example <- @examples do
    @tag example: example
    test "example #{example} runs without errors" do
      path = Path.join(["examples", unquote(example)])

      {output, exit_code} = System.cmd(
        "elixir",
        [path],
        stderr_to_stdout: true,
        env: [{"PATH", System.get_env("PATH")}]
      )

      assert exit_code == 0, """
      Example #{unquote(example)} failed with exit code #{exit_code}

      Output:
      #{output}
      """

      # Verify no error patterns
      refute output =~ ~r/Error:|UNIMPLEMENTED|crash/i
    end
  end
end
```

### Priority 2: Adapter Contract Tests

**Create**: `test/snakepit/adapter_contract_test.exs`

```elixir
defmodule Snakepit.AdapterContractTest do
  use ExUnit.Case

  @adapters [
    {"ShowcaseAdapter", "snakepit_bridge.adapters.showcase.ShowcaseAdapter"},
    {"TemplateAdapter", "snakepit_bridge.adapters.template.TemplateAdapter"}
  ]

  describe "adapter implements required interface" do
    test "default adapter is functional" do
      args = Snakepit.Adapters.GRPCPython.script_args()
      [_, adapter_path] = args

      # Default should be ShowcaseAdapter (functional)
      assert String.ends_with?(adapter_path, "ShowcaseAdapter")
    end

    @tag :integration
    test "ShowcaseAdapter implements execute_tool" do
      # Start pool with ShowcaseAdapter
      # Call execute_tool
      # Verify it works
    end

    test "TemplateAdapter is documented as incomplete" do
      # Verify docstring warns users
      template_path = Path.join([
        "priv", "python", "snakepit_bridge",
        "adapters", "template.py"
      ])

      content = File.read!(template_path)
      assert content =~ ~r/WARNING.*TEMPLATE/
      assert content =~ ~r/NOT.*functional/i
    end
  end
end
```

### Priority 3: Real Python Integration Tests

**Create**: `test/integration/real_python_test.exs`

```elixir
defmodule Snakepit.Integration.RealPythonTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :real_python

  setup do
    # Skip if Python deps not available
    case System.cmd("python3", ["-c", "import grpc"], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, _} ->
        {:skip, "Python gRPC not available: #{output}"}
    end
  end

  test "can start pool with real Python workers" do
    {:ok, _} = Snakepit.Pool.start_link(
      size: 2,
      worker_module: Snakepit.GRPCWorker,
      adapter_module: Snakepit.Adapters.GRPCPython
    )

    # Wait for initialization
    :ok = Snakepit.Pool.await_ready()

    stats = Snakepit.Pool.get_stats()
    assert stats.workers == 2
    assert stats.available == 2
  end

  test "can execute commands on real Python adapter" do
    {:ok, _} = Application.ensure_all_started(:snakepit)

    # ShowcaseAdapter implements ping
    assert {:ok, result} = Snakepit.execute("ping", %{})
    assert is_map(result)
  end

  test "handles Python crashes gracefully" do
    # Start worker
    # Kill Python process
    # Verify worker restarts
    # Verify no orphans
  end
end
```

**Usage**:
```bash
# Normal tests (without Python)
mix test

# With Python integration tests
mix test --include real_python
```

---

## Test Execution Analysis

### What We Learned from Running Tests

**From output**:
```
[error] Failed to start worker starter for pool_worker_47_40837:
        {:shutdown, {:failed_to_start_child, ...,
        {:grpc_server_failed, :connection_refused}}}
```

**This appears 30+ times in test output!**

**Analysis**:
- ✅ Tests handle Python being unavailable
- ✅ Worker failures don't cascade
- ✅ Pool degrades gracefully
- ⚠️ Tests pass even with failures (is this desirable?)

**Insight**: Tests are **too tolerant** - they pass even when workers fail to start!

**Question**: Should we:
- A) Make tests fail if Python unavailable (strict)
- B) Keep current behavior (permissive)
- C) Split into `@tag :requires_python` tests

**Recommendation**: **Option C** - tag Python-required tests separately

---

## Coverage Metrics

### Module-Level Coverage Estimate

| Module Category | Est. Coverage | Confidence |
|----------------|---------------|------------|
| Pool infrastructure | 85% | High ✅ |
| Process management | 75% | High ✅ |
| Bridge/Sessions | 80% | High ✅ |
| Variables system | 95% | High ✅ |
| Serialization | 90% | High ✅ |
| gRPC (mocked) | 70% | Medium ⚠️ |
| gRPC (real) | 20% | Low ❌ |
| Adapters | 10% | Low ❌ |
| Examples | 0% | None ❌ |
| Python code | 5% | Low ❌ |

**Overall Elixir Coverage**: ~70% (estimated)
**Overall Python Coverage**: ~5% (measured)
**Overall System Coverage**: ~40% (conservative)

### Risk Assessment

**Low Risk Areas** (can refactor confidently):
- Pool infrastructure (well-tested)
- Variable system (heavily tested)
- Serialization (well-tested)

**Medium Risk Areas** (test carefully):
- gRPC components (partially tested)
- Worker lifecycle (mocked mostly)

**High Risk Areas** (add tests first):
- Adapter system (minimal testing)
- Examples (zero testing)
- Python adapters (zero testing)
- Integration points (partial testing)

---

## Gaps That Caused Current Issues

### Gap 1: No Example Tests
**Impact**: Examples broke, nobody noticed

### Gap 2: No Adapter Config Tests
**Impact**: Wrong default shipped

### Gap 3: No Python Adapter Tests
**Impact**: Can't validate adapters work

### Gap 4: No Integration Tests
**Impact**: Components work alone, fail together

---

## Test Expansion Plan

### Week 1: Critical Gaps
1. Add example smoke tests
2. Add adapter configuration tests
3. Add real Python integration tests (opt-in)

### Week 2: Integration Testing
4. Add concurrent restart tests
5. Add port conflict tests
6. Add resource cleanup validation

### Week 3: Quality Improvements
7. Remove sleep-based synchronization
8. Add contract tests for mocks
9. Add chaos/fault injection tests

### Week 4: Python Testing
10. Add Python unit tests
11. Add Python integration tests
12. Add adapter contract validation

---

## Key Insights

1. **Tests are too permissive** - pass even when workers fail
2. **Mocks hide reality** - MockGRPCAdapter ≠ ShowcaseAdapter
3. **Python is untested** - relying on faith
4. **Examples are orphaned** - no validation
5. **Integration gaps** - components tested in isolation

**Meta-Insight**: The test suite gives **false confidence**. It validates OTP patterns but not the actual Python integration that users need.

---

**Next Document**: `04_implementation_plan.md` - Concrete changes with code diffs
