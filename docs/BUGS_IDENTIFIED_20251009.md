# Bugs Identified - 2025-10-09

## Critical Bugs Found During Variable System Removal

### Bug #1: PID Reuse Race Condition in ProcessRegistry Orphan Cleanup

**Severity:** HIGH
**Impact:** Workers fail to start with "Python gRPC server process exited with status 0"

**Root Cause:**
1. ProcessRegistry.init runs orphan cleanup at startup
2. Finds orphaned PIDs from previous BEAM run in DETS
3. Kills those PIDs immediately
4. BUT: OS may have reused those PIDs for NEW workers starting up
5. NEW workers get killed by accident

**Evidence:**
```
17:56:18.652 [warning] Orphaned PIDs: [410996]
17:56:18.658 [error] Python gRPC server process exited with status 0 during startup
```

**Location:** `lib/snakepit/pool/process_registry.ex:460-520`

**Fix Options:**
1. Add delay before killing (wait 5s to let new workers register)
2. Verify process command line still has OLD beam_run_id before killing
3. Use process start time to filter out recently-started processes

### Bug #2: Tests Pass Despite Worker Startup Failures

**Severity:** HIGH
**Impact:** Critical bugs go undetected

**Root Cause:**
- Tests don't verify that workers actually started successfully
- Tests don't check for error logs
- ApplicationCleanup kills failed workers, hiding the failure

**Evidence:**
- 28 tests pass even with "Python gRPC server process exited" errors
- No test failures when 2+ workers fail to start

**Fix:**
Created new tests:
- `test/snakepit/pool/worker_lifecycle_test.exs` - Verifies workers clean up properly
- `test/snakepit/pool/application_cleanup_test.exs` - Verifies cleanup doesn't kill current processes

**Recommendation:** All integration tests should assert workers started successfully

### Bug #3: Orphan Warnings During Normal Operation

**Severity:** LOW
**Impact:** Noise in logs, but cleanup works

**Root Cause:**
- ProcessRegistry orphan cleanup finds stale DETS entries from previous runs
- Warnings appear even though cleanup is working correctly

**Status:** NOT A BUG - This is expected behavior. The warnings indicate the safety net is working.

**Recommendation:** Reduce log level or change message to be less alarming

## Tests Created

### worker_lifecycle_test.exs
Tests that MUST FAIL if workers don't clean up Python processes properly.

**Key assertions:**
- Python process count drops to zero after Application.stop
- ApplicationCleanup doesn't kill processes during normal operation
- Multiple start/stop cycles don't leave orphans

### application_cleanup_test.exs
Tests that ApplicationCleanup only kills orphans, not current-run processes.

**Key assertion:**
- Process count remains stable during normal operation
- ApplicationCleanup doesn't run during normal operation

## Recommendations

1. **URGENT:** Fix ProcessRegistry PID reuse race (Bug #1)
2. Add worker startup verification to all integration tests
3. Consider moving orphan cleanup to background task with delay
4. Add telemetry events for worker startup failures
5. Make tests fail loudly when workers don't start

## Files Modified

- `test/snakepit/pool/worker_lifecycle_test.exs` (NEW)
- `test/snakepit/pool/application_cleanup_test.exs` (NEW)
- `test/support/test_case.ex` (attempted fix, reverted)

## Next Steps

1. Fix PID reuse race in ProcessRegistry
2. Run full test suite with fix
3. Verify zero orphan warnings and zero startup errors
4. Document the fix
