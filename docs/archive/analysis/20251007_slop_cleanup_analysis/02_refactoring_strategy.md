# Refactoring Strategy with Feedback Loops

**Date**: 2025-10-07
**Prerequisites**: Read `01_current_state_assessment.md` first
**Purpose**: Systematic approach to decrufting with validation at each step

---

## Philosophy

**Principle**: Every change must be **validated** before proceeding to the next.

**Feedback Loop Structure**:
```
1. Identify issue
2. Propose fix
3. ❓ Self-critique: What could go wrong?
4. Implement fix
5. ✅ Validate (test + example)
6. 📊 Measure impact
7. → Proceed or rollback
```

---

## Phase 1: Immediate Fixes (P0 - Day 1)

### Fix 1.1: Change Default Adapter

**Issue**: Examples fail because `EnhancedBridge` is incomplete

**Current Code**:
```elixir
# lib/snakepit/adapters/grpc_python.ex:32-39
def script_args do
  pool_config = Application.get_env(:snakepit, :pool_config, %{})
  adapter_args = Map.get(pool_config, :adapter_args, nil)

  if adapter_args do
    adapter_args
  else
    ["--adapter", "snakepit_bridge.adapters.enhanced.EnhancedBridge"]  # ❌ WRONG
  end
end
```

**Proposed Fix**:
```elixir
def script_args do
  pool_config = Application.get_env(:snakepit, :pool_config, %{})
  adapter_args = Map.get(pool_config, :adapter_args, nil)

  if adapter_args do
    adapter_args
  else
    # Default to ShowcaseAdapter - fully functional reference implementation
    ["--adapter", "snakepit_bridge.adapters.showcase.ShowcaseAdapter"]
  end
end
```

**Self-Critique** ❓:
- Q: What if ShowcaseAdapter is too heavy for production?
- A: Users can override via `:adapter_args` config
- Q: What if ShowcaseAdapter has dependencies (numpy, ML libs)?
- A: Check requirements.txt - it only needs base deps
- Q: What about existing code using EnhancedBridge?
- A: It was never functional, so no breaking change

**Validation Plan** ✅:
1. Run `mix test` - should still pass (160/160)
2. Run `elixir examples/grpc_basic.exs` - should now WORK
3. Check all other examples - should now work
4. Verify startup time doesn't increase significantly

**Expected Impact** 📊:
- ✅ All 9 examples should start working
- ✅ New users can follow tutorials
- ⚠️ Slightly slower startup (ShowcaseAdapter loads more code)
- ✅ Clear default "happy path"

**Rollback Plan**:
```bash
git checkout lib/snakepit/adapters/grpc_python.ex
```

---

### Fix 1.2: Rename EnhancedBridge → TemplateAdapter

**Issue**: "Enhanced" implies functional, but it's a bare template

**Changes**:
```bash
# Rename Python file
mv priv/python/snakepit_bridge/adapters/enhanced.py \
   priv/python/snakepit_bridge/adapters/template.py

# Update class name
sed -i 's/class EnhancedBridge/class TemplateAdapter/' \
  priv/python/snakepit_bridge/adapters/template.py

# Update docstring
```

**New Docstring**:
```python
"""
Template adapter for creating custom Snakepit adapters.

⚠️  WARNING: This is a TEMPLATE, not a functional adapter!

This adapter provides the minimal structure needed to create
a custom adapter. It does NOT implement execute_tool() or any
actual functionality.

For a working reference implementation, see ShowcaseAdapter.

To create a custom adapter:
1. Copy this file
2. Rename the class
3. Implement execute_tool()
4. Add your custom logic
5. Configure via :adapter_args
"""
```

**Self-Critique** ❓:
- Q: Will this break existing code?
- A: Nothing uses EnhancedBridge successfully (it's broken)
- Q: Should we keep EnhancedBridge as an alias?
- A: No - clean break, avoid confusion
- Q: What about documentation mentioning "Enhanced"?
- A: Update all docs in this refactor

**Validation** ✅:
1. `mix test` - should pass
2. Grep for "Enhanced" - update all references
3. Verify examples still work (now use ShowcaseAdapter)

**Expected Impact** 📊:
- ✅ Clear naming: Template = incomplete, Showcase = working
- ✅ No accidental usage of non-functional adapter
- ✅ Easier for users to create custom adapters

---

### Fix 1.3: Update All Examples

**Issue**: Examples don't specify adapter, rely on broken default

**Change**: Add explicit adapter configuration to each example

**Template Addition**:
```elixir
# At top of every example file, add comment:

# Configure Snakepit for gRPC
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)

# Optional: Use a custom Python adapter
# Application.put_env(:snakepit, :pool_config, %{
#   adapter_args: ["--adapter", "your.custom.Adapter"]
# })
# If not specified, uses ShowcaseAdapter (recommended for examples)

Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{pool_size: 2})
```

**Self-Critique** ❓:
- Q: Isn't this more verbose?
- A: Yes, but explicit is better than broken
- Q: What if we change defaults again?
- A: Examples are self-documenting with current behavior

**Validation** ✅:
```bash
for example in examples/*.exs; do
  echo "Testing $example..."
  PATH="$PWD/.venv/bin:$PATH" elixir "$example" && echo "✅ PASS" || echo "❌ FAIL"
done
```

**Expected Impact** 📊:
- ✅ All examples work
- ✅ Examples serve as documentation
- ✅ Clear configuration patterns

---

## Phase 2: Correctness Fixes (P1 - Week 1)

### Fix 2.1: Correct wait_for_resource_cleanup

**Issue**: Currently checks dead Elixir PID, should check external resources

**Current (WRONG)**:
```elixir
defp wait_for_worker_cleanup(pid, retries \\ 10) do
  if retries > 0 and Process.alive?(pid) do  # ❌ PID is already dead!
    ref = Process.monitor(pid)
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      100 -> wait_for_worker_cleanup(pid, retries - 1)
    end
  else
    :ok
  end
end
```

**Proposed (CORRECT)**:
```elixir
defp wait_for_resource_cleanup(worker_id, old_port, retries \\ 20) do
  if retries > 0 do
    cond do
      # Check 1: Is the port available?
      port_available?(old_port) and
      # Check 2: Is the registry entry cleaned up?
      registry_cleaned?(worker_id) ->
        Logger.debug("Resources released for #{worker_id}")
        :ok

      true ->
        Process.sleep(50)  # Shorter sleep, more retries
        wait_for_resource_cleanup(worker_id, old_port, retries - 1)
    end
  else
    Logger.warning("Resource cleanup timeout for #{worker_id}")
    {:error, :cleanup_timeout}
  end
end

defp port_available?(port) do
  case :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true]) do
    {:ok, socket} ->
      :gen_tcp.close(socket)
      true
    {:error, :eaddrinuse} ->
      false
    _ ->
      false  # Other errors = assume unavailable
  end
end

defp registry_cleaned?(worker_id) do
  case Snakepit.Pool.Registry.lookup(worker_id) do
    {:error, :not_found} -> true
    {:ok, _pid} -> false
  end
end
```

**Self-Critique** ❓:
- Q: What if port check interferes with OS?
- A: Using `reuseaddr` flag prevents issues
- Q: What if registry cleanup is delayed?
- A: 20 retries × 50ms = 1 second max wait
- Q: Could this introduce new race conditions?
- A: **Need integration test** to verify

**Validation** ✅:
```elixir
# New integration test
test "restart_worker waits for port release" do
  {:ok, _} = WorkerSupervisor.start_worker("test_worker")
  {:ok, old_pid} = Registry.get_worker_pid("test_worker")
  {:ok, port} = GenServer.call(old_pid, :get_port)

  # Restart should wait for port
  {:ok, _} = WorkerSupervisor.restart_worker("test_worker")

  # Verify new worker got same port (proving old one released it)
  {:ok, new_pid} = Registry.get_worker_pid("test_worker")
  {:ok, new_port} = GenServer.call(new_pid, :get_port)

  assert port == new_port
  assert old_pid != new_pid
end
```

**Expected Impact** 📊:
- ✅ Correct resource availability checking
- ✅ Prevents port binding race conditions
- ⚠️ Slightly slower restarts (up to 1 second wait)
- ✅ More robust worker replacement

**Rollback Plan**:
Keep old function as `wait_for_worker_cleanup_legacy`, switch back if issues

---

## Phase 3: Simplification (P2 - Week 1-2)

### Fix 3.1: Simplify ApplicationCleanup

**Issue**: Does too much, duplicates normal shutdown

**Current Behavior**:
1. Queries ProcessRegistry for all PIDs
2. Sends SIGTERM to all
3. Waits
4. Sends SIGKILL to survivors
5. Does `pkill` as fallback

**Proposed Behavior**:
1. **Trust GRPCWorker.terminate** to clean up normally
2. Only do emergency `pkill` for orphans
3. Emit telemetry when cleanup actually happens (indicates bug)

**New Implementation**:
```elixir
def terminate(_reason, _state) do
  Logger.info("🔍 Emergency cleanup check...")

  beam_run_id = Snakepit.Pool.ProcessRegistry.get_beam_run_id()
  orphaned = find_orphaned_processes(beam_run_id)

  if Enum.empty?(orphaned) do
    Logger.info("✅ No orphaned processes - supervision worked correctly")
    emit_telemetry(:cleanup_success, 0)
  else
    Logger.warning("⚠️  Found #{length(orphaned)} orphaned processes!")
    Logger.warning("This indicates supervision tree failed - INVESTIGATE")

    emit_telemetry(:orphaned_processes_found, length(orphaned))

    # Emergency kill
    System.cmd("pkill", ["-9", "-f", "grpc_server.py.*--snakepit-run-id #{beam_run_id}"])
    Logger.warning("🔥 Emergency killed orphaned processes")
  end

  :ok
end

defp find_orphaned_processes(beam_run_id) do
  case System.cmd("pgrep", ["-f", "grpc_server.py.*#{beam_run_id}"]) do
    {"", 1} -> []  # No processes
    {output, 0} -> String.split(output, "\n", trim: true)
    _ -> []
  end
end
```

**Self-Critique** ❓:
- Q: What if supervision DOES fail?
- A: Emergency pkill still runs - orphans still killed
- Q: How do we know if supervision is failing?
- A: Telemetry alerts when orphans found
- Q: What if pkill fails?
- A: Same as before - log error, best effort

**Validation** ✅:
1. Normal shutdown test - should log "No orphaned"
2. Chaos test - kill supervisor, should log warning
3. Telemetry test - verify events emitted

**Expected Impact** 📊:
- ✅ Clearer intent: emergency-only
- ✅ Diagnostic value: tells us when supervision fails
- ✅ Simpler code: ~100 LOC → ~50 LOC
- ✅ Faster normal shutdown (no unnecessary work)

---

### Fix 3.2: Remove Redundant Process.alive? Filter

**Issue**: `which_children` already returns live processes

**Current**:
```elixir
def list_workers do
  DynamicSupervisor.which_children(__MODULE__)
  |> Enum.map(fn {_, pid, _, _} -> pid end)
  |> Enum.filter(&Process.alive?/1)  # ❌ Redundant
end
```

**Proposed**:
```elixir
def list_workers do
  DynamicSupervisor.which_children(__MODULE__)
  |> Enum.map(fn {_, pid, _, _} -> pid end)
end
```

**Self-Critique** ❓:
- Q: What about TOCTOU race conditions?
- A: Any code using PIDs has TOCTOU - unavoidable
- Q: Could this break existing code?
- A: No - function contract unchanged
- Q: Performance impact?
- A: Faster (removes O(n) process checks)

**Validation** ✅:
```elixir
test "list_workers returns only live workers" do
  {:ok, pid1} = start_worker("w1")
  {:ok, pid2} = start_worker("w2")

  workers = list_workers()
  assert length(workers) == 2

  Process.exit(pid1, :kill)
  :timer.sleep(50)  # Allow cleanup

  workers = list_workers()
  assert length(workers) == 1
  assert pid2 in workers
end
```

**Expected Impact** 📊:
- ✅ Trusts OTP guarantees
- ✅ Slightly faster
- ✅ Cleaner code

---

## Phase 4: Documentation (P2 - Week 2)

### Doc 4.1: Add ADR for Worker.Starter Pattern

**Issue**: Pattern appears over-engineered without explanation

**Create**: `docs/architecture/adr-001-worker-starter-pattern.md`

```markdown
# ADR 001: Worker.Starter Supervision Pattern

## Status
Accepted

## Context
Workers manage external OS processes (Python gRPC servers). We need:
- Automatic restart on crashes
- Clean resource cleanup
- Future: per-worker resource grouping

## Decision
Use Worker.Starter supervisor wrapper pattern:

DynamicSupervisor (WorkerSupervisor)
└── Worker.Starter (Supervisor, permanent)
    └── GRPCWorker (GenServer, :transient)

## Rationale
1. **Automatic Restarts**: Worker.Starter restarts GRPCWorker automatically
2. **Pool Decoupling**: Pool doesn't manage worker lifecycle details
3. **Atomic Cleanup**: Terminating Starter terminates all related processes
4. **Future Extensibility**: Can add per-worker resources under Starter

## Alternatives Considered

### Alternative 1: Direct DynamicSupervisor
Start GRPCWorker directly under WorkerSupervisor.

Pros:
- Simpler (one less layer)
- Standard OTP pattern

Cons:
- Pool must handle restart logic
- Harder to add per-worker resources later
- Less encapsulation

### Alternative 2: Worker as Supervisor
Make GRPCWorker itself a Supervisor.

Pros:
- One fewer module

Cons:
- Violates single responsibility
- Mixing GenServer + Supervisor behavior

## Consequences

Positive:
- Workers auto-restart without Pool intervention
- Clean abstraction boundary
- Extensible for future needs

Negative:
- Extra process per worker (~1KB memory)
- More complex process tree
- Requires understanding non-standard pattern

## Review
Revisit in 6 months if no grouped resources materialize
```

**Self-Critique** ❓:
- Q: Does this justify the complexity?
- A: Shows conscious trade-off, not accidental complexity
- Q: What if we decide to remove it later?
- A: ADR documents the change reasoning

**Validation** ✅:
- Review by maintainers
- Reference in Issue #2 response

---

### Doc 4.2: Adapter Selection Guide

**Create**: `docs/guides/adapter-selection.md`

```markdown
# Adapter Selection Guide

## Available Adapters

### ShowcaseAdapter (Recommended for Examples)
**Location**: `snakepit_bridge.adapters.showcase.ShowcaseAdapter`

**Features**:
- ✅ Fully implemented `execute_tool`
- ✅ 13+ example tools
- ✅ Streaming support
- ✅ Variable system integration
- ✅ ML workflow demos

**Use When**:
- Learning Snakepit
- Running examples
- Need reference implementation
- Prototyping

**Configuration**:
```elixir
# Default - no config needed
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
```

### TemplateAdapter (For Custom Development)
**Location**: `snakepit_bridge.adapters.template.TemplateAdapter`

⚠️  **WARNING**: This is a TEMPLATE, not functional!

**Use When**:
- Creating a custom adapter
- Need minimal starting point

**Do NOT Use**:
- In production
- For examples
- When you need working tools

### Custom Adapters

**Creating Your Own**:
```python
from snakepit_bridge.base_adapter import BaseAdapter

class MyAdapter(BaseAdapter):
    def execute_tool(self, tool_name, arguments, context):
        if tool_name == "my_custom_tool":
            return {"result": "custom logic"}
        raise NotImplementedError(f"Unknown tool: {tool_name}")
```

**Configuration**:
```elixir
Application.put_env(:snakepit, :pool_config, %{
  adapter_args: ["--adapter", "my_package.MyAdapter"]
})
```

## Decision Matrix

| Need | Recommended Adapter |
|------|---------------------|
| Running examples | ShowcaseAdapter (default) |
| Learning Snakepit | ShowcaseAdapter |
| Production with custom logic | Custom adapter |
| ML/AI integration | Custom based on ShowcaseAdapter |
| Minimal overhead | Custom minimal adapter |
| Template for development | TemplateAdapter |
```

**Validation** ✅:
- User testing with new developers
- Reference in README

---

## Feedback Loops Summary

Each phase has built-in validation:

### Phase 1 Validation
```bash
# After each fix:
mix test                    # Unit tests
./test_examples.sh          # All examples
mix dialyzer               # Type checking
git diff --stat            # Review changes
```

### Phase 2 Validation
```bash
# Integration tests
mix test test/integration/
# Chaos testing
mix test.chaos.shutdown
# Performance benchmarks
mix test test/performance/
```

### Phase 3 Validation
```bash
# Code coverage
mix test --cover
# Check for regressions
mix test --only regression
# Memory profiling
:observer.start()
```

### Phase 4 Validation
```bash
# Documentation review
mix docs
# User testing
# Code review
```

---

## Rollback Strategy

**For each phase**:
1. Create branch: `refactor/phase-N-description`
2. Implement changes
3. Run full validation
4. If validation fails:
   - Document failure
   - Analyze root cause
   - Rollback: `git reset --hard origin/main`
   - Revise approach
5. If validation succeeds:
   - Merge to main
   - Tag: `refactor-phase-N-complete`

**Safety Net**:
- All changes in separate branches
- Main branch always working
- Can cherry-pick successful fixes
- Can abandon failed experiments

---

## Success Criteria

### Phase 1 Success
- ✅ All 9 examples work
- ✅ All 160 tests still pass
- ✅ No new warnings

### Phase 2 Success
- ✅ New integration tests pass
- ✅ No port binding race conditions
- ✅ Worker restarts are reliable

### Phase 3 Success
- ✅ Simpler code (LOC reduction)
- ✅ Same or better performance
- ✅ Clearer intent

### Phase 4 Success
- ✅ New users can configure adapters
- ✅ Design decisions documented
- ✅ Issue #2 concerns addressed in ADRs

---

**Next Document**: `03_implementation_checklist.md` - Step-by-step commands and verification
