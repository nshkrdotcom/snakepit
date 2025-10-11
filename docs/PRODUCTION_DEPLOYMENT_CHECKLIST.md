# Production Deployment Checklist

## Pre-Deployment Tasks

### 1. Remove Debug Logging

**Python (priv/python/grpc_server.py):**
- [ ] Remove all `/tmp/python_worker_debug.log` writes
- [ ] Remove signal reception logging (lines 767-770)
- [ ] Remove tombstone message (lines 799-803)
- [ ] Change logging level from INFO to WARNING

**Elixir:**
- [ ] Remove `IO.inspect` calls in lib/snakepit/process_killer.ex (lines 28-29, 109-110, 113-116)
- [ ] Remove `IO.inspect` calls in lib/snakepit/pool/application_cleanup.ex (lines 39-40, 43-44)
- [ ] Remove `IO.inspect` calls in lib/snakepit/application.ex (lines 21-26, 43-45, 76, 81-83)
- [ ] Remove "!!! GRPCWorker.terminate/2 CALLED !!!" in lib/snakepit/grpc_worker.ex (lines 448-449)

### 2. Fix Compiler Warnings

- [ ] Add `@impl true` to `Application.stop/1` (lib/snakepit/application.ex:80)
- [ ] Rename `_worker_id` to `worker_id` in lib/snakepit/pool/process_registry.ex:496

### 3. Final Verification

```bash
# Clean state
rm -rf priv/data/*.dets

# Run test suite
mix test
# Expected: 60 tests, 0 failures

# Test basic example
elixir examples/grpc_basic.exs
# Expected: "✅ No orphaned processes"

# Stress test with 100 workers
elixir examples/grpc_concurrent.exs 100
# Expected: Zero orphans after completion

# Verify no orphans
sleep 3
ps aux | grep grpc_server.py | grep -v grep
# Expected: No output (zero processes)
```

### 4. Update Documentation

- [ ] Update README.md with zero orphans achievement
- [ ] Add deployment notes about monitoring
- [ ] Document the trap_exit requirement

## Production Monitoring

### Key Metrics

**1. ApplicationCleanup Orphan Count**
```elixir
# Should be 0 in normal operation
:telemetry.attach(
  "orphan-monitor",
  [:snakepit, :application_cleanup, :orphaned_processes_found],
  fn _event, %{count: count}, _metadata, _config ->
    if count > 0 do
      Logger.error("ALERT: Found #{count} orphaned processes!")
    end
  end,
  nil
)
```

**2. Worker Restart Rate**
```bash
# Monitor supervisor restarts
watch -n 5 'ps aux | grep grpc_server.py | wc -l'
# Should stay constant (= pool_size)
```

**3. Process Count**
```bash
# Total Python processes should equal pool_size
ps aux | grep grpc_server.py | wc -l
```

**4. DETS File Size**
```bash
# Should stay small (< 100KB typically)
ls -lh priv/data/*.dets
```

### Alerts to Configure

1. **Orphan Detection:** Alert if ApplicationCleanup finds any orphans
2. **High Restart Rate:** Alert if >10 worker restarts/minute
3. **Process Count Mismatch:** Alert if Python process count != pool_size
4. **DETS Growth:** Alert if DETS file >1MB (indicates cleanup not running)

## Deployment Steps

1. **Remove debug logging** (see above)
2. **Fix warnings** (see above)
3. **Run final tests** (see above)
4. **Deploy to staging**
5. **Monitor for 24 hours**
6. **Verify zero orphans in staging**
7. **Deploy to production**
8. **Monitor ApplicationCleanup telemetry**

## Success Criteria

✅ Test suite passes (60/60)
✅ All examples show zero orphans
✅ 100-worker stress test shows zero orphans
✅ No ApplicationCleanup emergency activations in production
✅ Process count stable over time

## Rollback Plan

If orphans appear in production:
1. Check ApplicationCleanup telemetry logs
2. Verify GRPCWorker.terminate/2 being called (add temporary logging)
3. Check BEAM OS PID tracking in DETS
4. Review supervision tree configuration
5. If critical, rollback and investigate

---

**Status:** Ready for production deployment after debug logging removal
**Confidence:** HIGH - Zero orphans verified across all scenarios
