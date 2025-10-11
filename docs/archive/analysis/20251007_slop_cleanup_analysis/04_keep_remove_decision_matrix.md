# Keep/Remove Decision Matrix

**Date**: 2025-10-07
**Purpose**: Systematic evaluation of every module for retention or removal
**Methodology**: Evidence-based decision making with verification

---

## Decision Criteria

For each module, evaluate:

1. **Is it used?** (grep references in code)
2. **Is it tested?** (test coverage exists)
3. **Is it functional?** (implements complete behavior)
4. **Is it documented?** (purpose clear)
5. **Is it recent?** (active development)

**Score**: 5/5 = KEEP, 3-4/5 = FIX, 1-2/5 = REMOVE, 0/5 = DELETE IMMEDIATELY

---

## Elixir Modules Analysis

### Core Pool Modules

#### Snakepit.Pool ✅ KEEP (5/5)
- ✅ Used: Core API, referenced everywhere
- ✅ Tested: 35+ tests
- ✅ Functional: 160 tests pass
- ✅ Documented: Good moduledoc
- ✅ Recent: Active development

**Verdict**: **KEEP** - Essential core

---

#### Snakepit.Pool.WorkerSupervisor ✅ KEEP (5/5)
- ✅ Used: Referenced by Pool
- ✅ Tested: Supervision tests
- ✅ Functional: Works correctly
- ✅ Documented: Clear purpose
- ✅ Recent: Active

**Verdict**: **KEEP** - Core infrastructure

**Note**: Minor simplifications per Issue #2 (remove Process.alive? filter)

---

#### Snakepit.Pool.Worker.Starter ⚠️ KEEP + DOCUMENT (4/5)
- ✅ Used: Referenced by WorkerSupervisor
- ✅ Tested: Implicitly via integration
- ✅ Functional: Works
- ❌ Documented: No ADR for pattern choice
- ✅ Recent: Active

**Verdict**: **KEEP but ADD ADR**

**Issue #2 Concern**: Pattern appears over-engineered
**Reality**: Intentional design for external process management
**Action**: Add ADR explaining trade-offs

---

#### Snakepit.Pool.Registry ✅ KEEP (5/5)
**Verdict**: **KEEP** - Essential

---

#### Snakepit.Pool.ProcessRegistry ✅ KEEP (5/5)
**Verdict**: **KEEP** - Critical for orphan cleanup

---

#### Snakepit.Pool.ApplicationCleanup ⚠️ SIMPLIFY (4/5)
- ✅ Used: In Application supervision tree
- ✅ Tested: Implicitly
- ✅ Functional: Works
- ❌ Documented: Over-complex implementation
- ✅ Recent: Active

**Verdict**: **KEEP but SIMPLIFY**

**Issue #2 Concern**: Duplicates built-in cleanup
**Reality**: Needed for external processes, but over-engineered
**Action**: Simplify to emergency-only handler

---

### gRPC/Bridge Modules

#### Snakepit.GRPCWorker ✅ KEEP (5/5)
- ✅ Used: Default worker type
- ✅ Tested: Multiple test files
- ✅ Functional: Works with ShowcaseAdapter
- ✅ Documented: Good moduledoc
- ✅ Recent: Very active

**Verdict**: **KEEP** - Core worker implementation

---

#### Snakepit.GRPC.BridgeServer ✅ KEEP (5/5)
- ✅ Used: gRPC server endpoint
- ✅ Tested: bridge_server_test.exs
- ✅ Functional: Works
- ✅ Documented: Detailed
- ✅ Recent: Active

**Verdict**: **KEEP** - Critical for gRPC

---

#### Snakepit.GRPC.Client ✅ KEEP (5/5)
**Verdict**: **KEEP** - Essential

---

#### Snakepit.GRPC.ClientImpl ✅ KEEP (5/5)
**Verdict**: **KEEP** - Implementation detail

---

#### Snakepit.GRPC.StreamHandler ⚠️ INVESTIGATE (3/5)
- ❌ Used: 0 external references
- ⚠️ Tested: Unclear
- ⚠️ Functional: Unknown
- ✅ Documented: Has moduledoc
- ✅ Recent: Active

**Verdict**: **INVESTIGATE** - Might be used dynamically

**Action**: Check if used in streaming operations

---

#### Snakepit.GRPC.Endpoint ⚠️ INVESTIGATE (3/5)
- ⚠️ Used: 2 references
- ⚠️ Tested: Unclear
- ⚠️ Functional: Unknown
- ✅ Documented: Has moduledoc
- ✅ Recent: Active

**Verdict**: **INVESTIGATE** - Likely part of gRPC server setup

---

### Bridge Modules

#### Snakepit.Bridge.SessionStore ✅ KEEP (5/5)
**Verdict**: **KEEP** - Heavily used and tested

---

#### Snakepit.Bridge.Serialization ✅ KEEP (5/5)
**Verdict**: **KEEP** - Core functionality

---

#### Snakepit.Bridge.ToolRegistry ✅ KEEP (5/5)
**Verdict**: **KEEP** - Used by tool bridge

---

#### Snakepit.Bridge.Variables.* ⚠️ EVALUATE (4/5)
- ✅ Used: By ShowcaseAdapter, BridgeServer
- ✅ Tested: 25+ tests (excellent coverage!)
- ✅ Functional: Works
- ✅ Documented: Well documented
- ✅ Recent: Active

**Verdict**: **KEEP** - Well-implemented feature

**Question**: Is this core to snakepit or should it be opt-in?

**Evidence**:
- ShowcaseAdapter uses it extensively
- BridgeServer has RPCs for it
- Has 8 variable type modules (String, Integer, Float, Boolean, Choice, Tensor, Embedding, Module)
- ~800 LOC total

**Decision**: **KEEP** - It's a differentiating feature, well-tested

---

### Adapter Modules

#### Snakepit.Adapters.GRPCPython ✅ KEEP + FIX (4/5)
- ✅ Used: Default adapter
- ⚠️ Tested: Minimal
- ⚠️ Functional: Yes, but wrong default
- ✅ Documented: Good
- ✅ Recent: Active

**Verdict**: **KEEP + FIX DEFAULT**

**Issue**: Defaults to EnhancedBridge (broken)
**Fix**: Default to ShowcaseAdapter
**Impact**: All examples start working

---

#### Snakepit.Adapters.GRPCBridge ❌ REMOVE (1/5)
- ❌ Used: 0 references (dead code!)
- ❌ Tested: No tests
- ⚠️ Functional: Uses EnhancedBridge (broken)
- ✅ Documented: Has moduledoc
- ⚠️ Recent: Last modified July

**Verdict**: **REMOVE** - Unused duplicate of GRPCPython

**Evidence**:
```bash
$ grep -r "GRPCBridge" lib/ test/ examples/ --include="*.ex*"
# Only result: lib/snakepit/adapters/grpc_bridge.ex:defmodule ...
```

**Action**: Delete `lib/snakepit/adapters/grpc_bridge.ex`

---

#### Snakepit.Python ❌ DEPRECATE (2/5)
- ❌ Used: 0 real usage (only docstring examples)
- ⚠️ Tested: 1 test file (only arg construction)
- ❌ Functional: References non-existent `EnhancedPython` adapter
- ✅ Documented: Extensive docs
- ⚠️ Recent: Modified in July

**Verdict**: **DEPRECATE or FIX**

**Evidence of Non-Functionality**:
```elixir
# lib/snakepit/python.ex:22
config :snakepit,
  adapter_module: Snakepit.Adapters.EnhancedPython  # ❌ DOESN'T EXIST
```

**Options**:
1. **DELETE** - Remove entirely (nothing uses it)
2. **FIX** - Implement `Snakepit.Adapters.EnhancedPython`
3. **DEPRECATE** - Mark as deprecated, remove in v0.5

**Recommendation**: **DELETE**

**Rationale**:
- Not used by any code
- References non-existent adapter
- API overlaps with tool-based approach
- Adds complexity without value
- If needed later, can restore from git

---

### Support Modules

#### Snakepit.Telemetry ✅ KEEP (4/5)
- ⚠️ Used: Few references
- ⚠️ Tested: Partial
- ✅ Functional: Works
- ✅ Documented: Yes
- ✅ Recent: Active

**Verdict**: **KEEP** - Infrastructure

**Note**: Expand telemetry for better monitoring

---

#### Snakepit.SessionHelpers ✅ KEEP (4/5)
**Verdict**: **KEEP** - Convenience API

---

#### Snakepit.Utils ✅ KEEP (4/5)
**Verdict**: **KEEP** - Utilities

---

#### Snakepit (main API) ✅ KEEP (5/5)
**Verdict**: **KEEP** - Public API

---

## Python Modules Analysis

### Core Infrastructure

#### grpc_server.py ✅ KEEP (5/5)
- ✅ Used: Main server entry point
- ⚠️ Tested: Only via integration
- ✅ Functional: Works
- ✅ Documented: Good comments
- ✅ Recent: Very active

**Verdict**: **KEEP** - Essential

---

#### snakepit_bridge/ package ✅ KEEP (5/5)
- ✅ Used: Core Python infrastructure
- ⚠️ Tested: Minimal
- ✅ Functional: Works
- ✅ Documented: Reasonable
- ✅ Recent: Active

**Verdict**: **KEEP** - Core package

**Includes**:
- `session_context.py` ✅
- `serialization.py` ✅
- `base_adapter.py` ✅
- `types.py` ✅
- All KEEP

---

### Python Adapters

#### ShowcaseAdapter ✅ KEEP (5/5)
- ✅ Used: Should be default
- ⚠️ Tested: Only via manual testing
- ✅ Functional: Fully implements execute_tool
- ✅ Documented: Well documented
- ✅ Recent: Very active (v0.4.1)

**Verdict**: **KEEP + SET AS DEFAULT**

**Includes all handlers**:
- `basic_ops.py` ✅ KEEP
- `binary_ops.py` ✅ KEEP
- `concurrent_ops.py` ✅ KEEP
- `ml_workflow.py` ✅ KEEP
- `session_ops.py` ✅ KEEP
- `streaming_ops.py` ✅ KEEP
- `variable_ops.py` ✅ KEEP

---

#### EnhancedBridge → TemplateAdapter ⚠️ RENAME (3/5)
- ❌ Used: Default but broken
- ❌ Tested: No tests
- ❌ Functional: Template only, no execute_tool
- ⚠️ Documented: Minimal
- ✅ Recent: Active

**Verdict**: **RENAME + DOCUMENT**

**Changes**:
1. Rename file: `enhanced.py` → `template.py`
2. Rename class: `EnhancedBridge` → `TemplateAdapter`
3. Add big warning in docstring
4. Keep as reference template

---

#### DSPyStreaming ⚠️ INVESTIGATE (3/5)
- ❌ Used: No direct references
- ❌ Tested: No tests
- ⚠️ Functional: Implements streaming, not execute_tool
- ✅ Documented: Has docstring
- ⚠️ Recent: Some activity

**Verdict**: **INVESTIGATE or REMOVE**

**Question**: Is this used for DSPy integration?

**Action**: Check if any examples/tests reference DSPy

---

#### GRPCStreaming ⚠️ MERGE or REMOVE (2/5)
- ❌ Used: No references
- ❌ Tested: No tests
- ⚠️ Functional: Has some commands
- ⚠️ Documented: Minimal
- ⚠️ Recent: Unknown

**Verdict**: **MERGE into ShowcaseAdapter or REMOVE**

**Overlap**: ShowcaseAdapter already has streaming_ops.py

**Action**: Remove if redundant

---

## Generated Code

### Protobuf Generated Files ✅ KEEP (N/A)
- `snakepit_bridge.pb.ex`
- `snakepit.pb.ex`
- `snakepit_bridge_pb2.py`
- `snakepit_bridge_pb2_grpc.py`

**Verdict**: **KEEP** - Generated, don't modify

---

## Examples Analysis

### Working Examples

#### bidirectional_tools_demo.exs ✅ KEEP (5/5)
- ✅ Works: Confirmed working
- ✅ Demonstrates: Full feature set
- ✅ Documented: Clear comments
- ✅ Recent: Latest features

**Verdict**: **KEEP** - Reference example

---

### Broken Examples (Missing Adapter Config)

All of these score **2/5**:
- ❌ Works: Broken (wrong adapter)
- ✅ Demonstrates: Would show features if fixed
- ⚠️ Documented: Some comments
- ✅ Recent: From v0.4

#### grpc_basic.exs ✅ FIX (2/5 → 5/5)
**Verdict**: **FIX** - Change to ShowcaseAdapter

#### grpc_advanced.exs ✅ FIX (2/5 → 5/5)
**Verdict**: **FIX** - Change to ShowcaseAdapter

#### grpc_concurrent.exs ✅ FIX (2/5 → 5/5)
**Verdict**: **FIX** - Change to ShowcaseAdapter + add error handling

#### grpc_sessions.exs ✅ FIX (2/5 → 5/5)
**Verdict**: **FIX** - Change to ShowcaseAdapter

#### grpc_streaming.exs ✅ FIX (2/5 → 5/5)
**Verdict**: **FIX** - Change to ShowcaseAdapter

#### grpc_streaming_demo.exs ✅ FIX (2/5 → 5/5)
**Verdict**: **FIX** - Change to ShowcaseAdapter

#### grpc_variables.exs ✅ FIX (2/5 → 5/5)
**Verdict**: **FIX** - Change to ShowcaseAdapter

---

#### bidirectional_tools_demo_auto.exs ⚠️ EVALUATE (3/5)
**Verdict**: **KEEP** - Interactive demo

---

### Example Projects

#### examples/snakepit_showcase/ ⚠️ INVESTIGATE (3/5)
- ⚠️ Works: Unknown
- ⚠️ Demonstrates: Full Mix project
- ✅ Documented: Has its own tests
- ✅ Recent: Active

**Verdict**: **KEEP** - Valuable full-project example

**Action**: Test if it works

---

#### examples/snakepit_loadtest/ ⚠️ INVESTIGATE (3/5)
**Verdict**: **KEEP** - Performance testing tool

**Action**: Test if it works

---

## Removal Candidates (DELETE ❌)

### HIGH CONFIDENCE - Delete Now

#### 1. Snakepit.Adapters.GRPCBridge (0/5)
- ❌ Used: Never
- ❌ Tested: Never
- ❌ Functional: Uses broken EnhancedBridge
- ⚠️ Documented: Yes but irrelevant
- ⚠️ Recent: Stale

**Evidence**:
```bash
$ grep -r "GRPCBridge" lib/ test/ examples/ --include="*.ex*"
# ZERO results except the definition itself
```

**Risk**: ZERO - nothing uses it

**Action**: `rm lib/snakepit/adapters/grpc_bridge.ex`

---

#### 2. Snakepit.Python (1/5)
- ❌ Used: Never (only docstring examples)
- ⚠️ Tested: Fake tests (only arg construction)
- ❌ Functional: References non-existent adapter
- ✅ Documented: Extensive (but useless)
- ⚠️ Recent: Modified July but unused

**Evidence**:
```elixir
# lib/snakepit/python.ex:22 (in docstring)
adapter_module: Snakepit.Adapters.EnhancedPython  # ❌ DOESN'T EXIST

# No actual usage:
$ grep "Snakepit\.Python\." lib/ test/ examples/ --include="*.ex*" \
  | grep -v "defmodule\|@moduledoc"
# ZERO results
```

**Risk**: LOW - only one test file to update

**Action**:
1. Delete `lib/snakepit/python.ex`
2. Delete `test/snakepit/python_test.exs`
3. Remove from documentation

**Rationale**:
- API is aspirational, never implemented
- References non-existent adapter
- Tool-based approach (`Snakepit.execute`) is the real API
- 530 LOC of dead code

---

### MEDIUM CONFIDENCE - Investigate Then Decide

#### 3. DSPyStreaming Adapter (2/5)
- ❌ Used: No references
- ❌ Tested: No
- ⚠️ Functional: Partial (streaming only)
- ⚠️ Documented: Minimal
- ⚠️ Recent: Unknown

**Action**: Search for DSPy usage

```bash
grep -r "dspy\|DSPy" lib/ test/ examples/ --include="*.ex*"
```

**If found**: Keep
**If not found**: Remove

---

#### 4. GRPCStreaming Adapter (2/5)
- ❌ Used: No references
- ❌ Tested: No
- ⚠️ Functional: Has some commands
- ⚠️ Documented: Minimal
- ⚠️ Recent: Unknown

**Action**: Compare with ShowcaseAdapter streaming

**If redundant**: Remove
**If different**: Document differences and keep

---

## Summary Tables

### Elixir: KEEP (32 modules)

| Module | Notes |
|--------|-------|
| All `Snakepit.Pool.*` | Core - keep all (8 modules) |
| All `Snakepit.GRPC.*` | Core - keep all (8 modules) |
| All `Snakepit.Bridge.*` | Feature - keep all (14 modules) |
| `Snakepit.Adapter` | Behavior - keep |
| `Snakepit` main API | API - keep |

### Elixir: REMOVE (2 modules)

| Module | Reason |
|--------|--------|
| `Snakepit.Adapters.GRPCBridge` | Dead code - 0 references |
| `Snakepit.Python` | Dead code - references non-existent adapter |

### Elixir: INVESTIGATE (4 modules)

| Module | Question |
|--------|----------|
| `Snakepit.GRPC.StreamHandler` | Used dynamically? |
| `Snakepit.GRPC.Endpoint` | Part of setup? |
| Generated protobuf modules | Keep but verify |

### Python: KEEP (Core + ShowcaseAdapter)

- `grpc_server.py` ✅
- `snakepit_bridge/` core package ✅
- `ShowcaseAdapter` + all handlers ✅
- Generated protobuf ✅

### Python: RENAME

- `enhanced.py` → `template.py` ⚠️

### Python: INVESTIGATE/REMOVE

- `dspy_streaming.py` ❓
- `grpc_streaming.py` ❓

---

## Examples: FIX ALL (8 files)

**Root Cause**: Wrong default adapter

**Fix**: Single line change in each:
```diff
# No change needed - just fix the default!
```

**After fixing default adapter, examples should work as-is!**

---

## Impact Analysis

### If We Remove:

#### Snakepit.Adapters.GRPCBridge
- Lines removed: ~95
- Files affected: 0 (no dependencies)
- Tests affected: 0
- Examples affected: 0
- **Risk**: ZERO

#### Snakepit.Python
- Lines removed: ~530
- Files affected: 1 test file
- Tests affected: 1 (python_test.exs)
- Examples affected: 0
- **Risk**: VERY LOW

**Total LOC Reduction**: ~625 lines of dead code

---

## Dependency Chains

### What Depends on What

**Critical Path** (must keep all):
```
Snakepit (API)
└── Snakepit.Pool
    └── Snakepit.Pool.WorkerSupervisor
        └── Snakepit.Pool.Worker.Starter
            └── Snakepit.GRPCWorker
                ├── Snakepit.Adapters.GRPCPython
                └── Snakepit.GRPC.Client
                    └── Snakepit.GRPC.ClientImpl
```

**Bridge Path** (for variables/tools):
```
Snakepit.GRPCWorker
└── Starts Python grpc_server.py
    └── Loads ShowcaseAdapter
        └── Uses Snakepit.Bridge.* modules (via gRPC)
            ├── SessionStore
            ├── Serialization
            ├── ToolRegistry
            └── Variables
```

**Orphaned** (no dependents):
```
Snakepit.Adapters.GRPCBridge  ❌ DELETE
Snakepit.Python                ❌ DELETE
```

---

## Verification Commands

### Before Removal
```bash
# Verify GRPCBridge has no references
grep -r "GRPCBridge" lib/ test/ examples/ --include="*.ex*"
# Should show only the definition

# Verify Snakepit.Python has no real usage
grep "Snakepit\.Python\." lib/ test/ examples/ --include="*.ex*" \
  | grep -v "defmodule\|@moduledoc\|@doc"
# Should show only docstring examples
```

### After Removal
```bash
# Ensure tests still pass
mix compile  # Should compile successfully
mix test     # Should pass 159/160 (1 less from python_test.exs)

# Ensure examples work
for ex in examples/*.exs; do
  echo "Testing $ex"
  elixir "$ex" 2>&1 | grep -q "Error\|crash" && echo "❌ FAIL" || echo "✅ PASS"
done
```

---

## Decision Summary

### KEEP (38 modules)
- Core pool infrastructure (8)
- gRPC communication (6)
- Bridge/session/variables (14)
- Support/utils (3)
- Adapters (1 - GRPCPython)
- Python core + ShowcaseAdapter (6)

### REMOVE (2 modules)
- `Snakepit.Adapters.GRPCBridge` - dead code
- `Snakepit.Python` - references non-existent dependency

### RENAME (1 module)
- `EnhancedBridge` → `TemplateAdapter`

### FIX (9 files)
- `GRPCPython` - change default adapter
- 8 example files - will work after default fix

### INVESTIGATE (2-3 modules)
- `DSPyStreaming` - check for usage
- `GRPCStreaming` - check for redundancy

### SIMPLIFY (2 modules per Issue #2)
- `ApplicationCleanup` - simplify to emergency-only
- `WorkerSupervisor` - remove Process.alive? filter

---

**Next Document**: `05_implementation_plan.md` - Step-by-step execution with code diffs
