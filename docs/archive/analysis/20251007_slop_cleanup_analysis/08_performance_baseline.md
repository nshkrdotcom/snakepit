# Performance Baseline & Metrics

**Date**: 2025-10-07
**Purpose**: Track performance across refactoring changes
**Key Metric**: Snakepit's 1000x concurrent initialization speedup

---

## Quick Start

```bash
# Run baseline benchmark
elixir bench/performance_baseline.exs

# View latest results
elixir bench/compare_results.exs latest

# Compare before/after refactoring
elixir bench/compare_results.exs bench/results/before.json bench/results/after.json
```

---

## Metrics Tracked

### 1. **Startup Performance (Concurrent Initialization)**
- **What**: Time to start N workers concurrently vs sequentially
- **Why**: Snakepit's key differentiator - 1000x faster than sequential
- **Goal**: Maintain sub-second startup even at 16+ workers

Example output:
```
Pool size 2: 250ms total, 125ms per worker
Pool size 4: 280ms total, 70ms per worker    ← 4x workers, only 30ms slower
Pool size 8: 320ms total, 40ms per worker    ← Scales nearly linearly!
Pool size 16: 450ms total, 28ms per worker   ← Still under 500ms!
```

**Target**: Pool of 16 workers in < 1 second (vs 16+ seconds sequential)

---

### 2. **Throughput (requests/second)**
- **What**: Simple ping requests, high concurrency
- **Why**: Validates pool can handle burst traffic
- **Goal**: > 1000 req/s with 8-worker pool

Example:
```
100 requests in 0.15s = 666 req/s
```

**Note**: gRPC has higher per-request overhead but scales better under load

---

### 3. **Latency Distribution**
- **What**: P50, P95, P99 latency for simple operations
- **Why**: Ensures consistent performance, no long tail
- **Goal**: P99 < 10ms for ping operations

Example:
```
Min: 0.8ms
P50: 1.2ms
P95: 2.5ms
P99: 4.8ms   ← Most requests under 5ms
Max: 12.3ms
```

---

### 4. **Concurrent Scaling**
- **What**: Performance with 10, 50, 100 concurrent requests
- **Why**: Validates OTP supervision handles contention
- **Goal**: Linear or better scaling up to 100 concurrent

Example:
```
10 concurrent: 45ms, 222 req/s
50 concurrent: 180ms, 278 req/s   ← Better throughput!
100 concurrent: 350ms, 286 req/s  ← Still scaling well
```

---

## Baseline Procedure

### Before Major Changes:

```bash
# 1. Ensure clean state
git stash
mix clean
rm -rf _build

# 2. Install deps
mix deps.get
mix compile

# 3. Ensure Python environment
source .venv/bin/activate  # or your venv
pip install -r priv/python/requirements.txt

# 4. Run baseline
elixir bench/performance_baseline.exs

# 5. Save as "before"
cp bench/results/baseline_*.json bench/results/before_refactor.json
```

### After Changes:

```bash
# 1. Run benchmark
elixir bench/performance_baseline.exs

# 2. Compare
elixir bench/compare_results.exs \
  bench/results/before_refactor.json \
  bench/results/baseline_*.json
```

---

## Performance Targets

### Must Not Regress:
- ✅ Startup time: < 1 second for 16 workers
- ✅ Throughput: > 500 req/s (8 workers)
- ✅ Latency P99: < 10ms
- ✅ Scaling: Linear up to 100 concurrent

### Nice to Have:
- 🎯 Startup: < 500ms for 16 workers
- 🎯 Throughput: > 1000 req/s
- 🎯 Latency P99: < 5ms
- 🎯 Scaling: Super-linear (better with more workers)

---

## gRPC vs Direct Communication

### gRPC Benefits:
- ✅ HTTP/2 multiplexing (multiple concurrent streams)
- ✅ Structured protocol buffers (type safety)
- ✅ Built-in health checks
- ✅ Better for streaming workloads

### gRPC Tradeoffs:
- ⚠️ Higher startup cost (~50-100ms per worker)
- ⚠️ Slightly higher per-request overhead (~0.5-1ms)
- ⚠️ More complex error handling

### When gRPC Wins:
- Long-running workers (startup cost amortized)
- Streaming operations (progress updates)
- Multiple concurrent requests per worker
- Complex data structures

### When Direct Protocol Wins:
- Short-lived workers
- Simple request/response
- Minimal latency critical
- Simpler deployment

---

## Historical Baselines

### v0.4.1 (before refactor):
```
Startup (8 workers): ~350ms
Throughput: ~800 req/s
Latency P99: ~6ms
Adapter: EnhancedBridge → ShowcaseAdapter
```

### Post-refactor targets:
```
Startup (8 workers): < 400ms (within 15% of baseline)
Throughput: > 700 req/s (within 15% of baseline)
Latency P99: < 7ms (within 15% of baseline)
Adapter: ShowcaseAdapter (fully functional)
```

---

## Regression Detection

If any metric regresses > 20%:
1. **STOP** - Do not merge
2. **Investigate** - Profile with :observer.start()
3. **Fix** - Optimize or rollback change
4. **Re-benchmark** - Validate fix
5. **Document** - Explain in PR why change needed

---

## Performance Optimization Guide

### If Startup Too Slow:
- Check worker initialization order (concurrent vs sequential)
- Profile `Worker.Starter` and `Pool` initialization
- Verify Python imports not blocking startup
- Check port open/close timing

### If Throughput Too Low:
- Increase pool size
- Check queue saturation (`Snakepit.get_stats()`)
- Profile request dispatch in `Pool`
- Verify no synchronization bottlenecks

### If Latency Too High:
- Profile gRPC communication overhead
- Check Python adapter execution time
- Verify no unnecessary serialization
- Look for blocking operations in hot path

### If Scaling Poor:
- Check for locks/synchronization points
- Profile ETS/Registry contention
- Verify worker isolation (no shared state)
- Check Python GIL impact (use multiprocessing if needed)

---

## Future Enhancements

### Planned Metrics:
- [ ] Memory usage tracking (process + Python)
- [ ] Error rate monitoring
- [ ] Worker restart frequency
- [ ] Session affinity impact
- [ ] Binary serialization speedup (>10KB payloads)

### Advanced Benchmarks:
- [ ] Real ML workload (embeddings, inference)
- [ ] Streaming performance
- [ ] Multi-session concurrency
- [ ] Resource cleanup speed
- [ ] Crash recovery time

---

## See Also

- [Performance section in README](../../README.md#performance)
- [OTP architecture decisions](06_issue_2_resolution.md)
- [Refactoring strategy](02_refactoring_strategy.md)
