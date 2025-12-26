# Snakepit Multi-Threaded Python Workers

Guide to writing thread-safe adapters for Python 3.13+ free-threading mode.

## Table of Contents

1. [Overview](#overview)
2. [When to Use Threaded Mode](#when-to-use-threaded-mode)
3. [Quick Start](#quick-start)
4. [Thread Safety Patterns](#thread-safety-patterns)
5. [Writing Thread-Safe Adapters](#writing-thread-safe-adapters)
6. [Testing for Thread Safety](#testing-for-thread-safety)
7. [Performance Optimization](#performance-optimization)
8. [Common Pitfalls](#common-pitfalls)
9. [Library Compatibility](#library-compatibility)

---

## Overview

Snakepit v0.7.4 includes **multi-threaded Python workers** that can handle multiple concurrent requests within a single Python process. This is designed for Python 3.13+ free-threading mode (PEP 703) which removes the Global Interpreter Lock (GIL).

### Architecture Comparison

| Mode | Description | Best For |
|------|-------------|----------|
| **Process** | Many single-threaded Python processes | I/O-bound, legacy Python, high concurrency |
| **Thread** | Few multi-threaded Python processes | CPU-bound, Python 3.13+, large data |

---

## When to Use Threaded Mode

✅ **Use threaded mode when:**
- Running Python 3.13+ with free-threading enabled
- CPU-intensive workloads (NumPy, PyTorch, data processing)
- Large shared data (models, configurations)
- Low memory overhead required

❌ **Use process mode when:**
- Running Python ≤3.12 (GIL present)
- Thread-unsafe libraries (Pandas, Matplotlib, SQLite3)
- Maximum process isolation needed
- Debugging thread issues

---

## Quick Start

### 1. Start Threaded Server

```bash
python grpc_server_threaded.py \
    --port 50052 \
    --adapter snakepit_bridge.adapters.threaded_showcase.ThreadedShowcaseAdapter \
    --elixir-address localhost:50051 \
    --max-workers 16 \
    --thread-safety-check
```

### 2. Configure Pool in Elixir

```elixir
# config/config.exs
config :snakepit,
  pools: [
    %{
      name: :hpc_pool,
      worker_profile: :thread,
      pool_size: 4,  # 4 processes
      threads_per_worker: 16,  # 64 total capacity
      adapter_module: Snakepit.Adapters.GRPCPython,
      adapter_args: ["--mode", "threaded", "--max-workers", "16"],
      adapter_env: [
        {"OPENBLAS_NUM_THREADS", "16"},
        {"OMP_NUM_THREADS", "16"}
      ]
    }
  ]
```

### 3. Execute from Elixir

```elixir
{:ok, result} = Snakepit.execute(:hpc_pool, "compute_intensive", %{data: [1,2,3]})
```

---

## Thread Safety Patterns

### Pattern 1: Shared Read-Only Resources

Resources that are loaded once and never modified are safe for concurrent access.

```python
class MyAdapter(ThreadSafeAdapter):
    __thread_safe__ = True

    def __init__(self):
        super().__init__()
        # Safe: Loaded once, never modified
        self.model = load_pretrained_model()
        self.config = {"timeout": 30, "batch_size": 10}
```

**Examples:** Pre-trained models, configuration dictionaries, lookup tables

### Pattern 2: Thread-Local Storage

Per-thread isolated state that doesn't need sharing.

```python
@thread_safe_method
def predict(self, input_data):
    # Safe: Each thread has its own cache
    cache = self.get_thread_local('cache', {})

    if input_data in cache:
        return cache[input_data]

    result = self.model.predict(input_data)

    # Update thread-local cache
    cache[input_data] = result
    self.set_thread_local('cache', cache)

    return result
```

**Examples:** Caches, temporary buffers, request-specific state

### Pattern 3: Locked Access to Shared Mutable State

State that must be shared and modified requires explicit locking.

```python
@thread_safe_method
def log_prediction(self, prediction):
    # Safe: Protected by lock
    with self.acquire_lock():
        self.prediction_log.append({
            "prediction": prediction,
            "timestamp": time.time()
        })
        self.total_predictions += 1
```

**Examples:** Shared counters, logs, accumulated results

---

## Writing Thread-Safe Adapters

### Step 1: Declare Thread Safety

```python
from snakepit_bridge.base_adapter_threaded import ThreadSafeAdapter, thread_safe_method, tool

class MyAdapter(ThreadSafeAdapter):
    __thread_safe__ = True  # Required declaration
```

### Step 2: Initialize Safely

```python
def __init__(self):
    super().__init__()  # Initialize base class

    # Pattern 1: Shared read-only
    self.model = load_model()

    # Pattern 3: Shared mutable (will need locking)
    self.request_count = 0
    self.results = []
```

### Step 3: Use Decorators

```python
@thread_safe_method
@tool(description="Thread-safe prediction")
def predict(self, input_data: str) -> dict:
    # Method is automatically tracked and protected
    result = self.model.predict(input_data)

    # Update shared state with lock
    with self.acquire_lock():
        self.request_count += 1

    return {"prediction": result}
```

### Step 4: Handle Shared State

```python
@thread_safe_method
def get_stats(self) -> dict:
    # Read shared mutable state safely
    with self.acquire_lock():
        return {
            "request_count": self.request_count,
            "results_count": len(self.results)
        }
```

---

## Testing for Thread Safety

### Method 1: Thread Safety Checker

```python
from snakepit_bridge.thread_safety_checker import ThreadSafetyChecker

# Enable checking
checker = ThreadSafetyChecker(enabled=True, strict_mode=False)

# Run your tests
def test_concurrent_access():
    adapter = MyAdapter()

    def make_request(i):
        adapter.predict(f"input_{i}")

    threads = [threading.Thread(target=make_request, args=(i,)) for i in range(100)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    # Get report
    report = checker.get_report()
    print(report)
```

### Method 2: Stress Testing

```python
import concurrent.futures

def stress_test_adapter():
    adapter = MyAdapter()

    with concurrent.futures.ThreadPoolExecutor(max_workers=20) as executor:
        futures = [executor.submit(adapter.predict, f"input_{i}") for i in range(1000)]
        results = [f.result() for f in futures]

    assert len(results) == 1000
    print("Stress test passed!")
```

### Method 3: Race Condition Detection

```python
def test_race_conditions():
    adapter = MyAdapter()
    results = []

    def increment():
        for _ in range(1000):
            # This WILL have race conditions without locking!
            adapter.counter += 1

    threads = [threading.Thread(target=increment) for _ in range(10)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    # If thread-unsafe, counter will be < 10000
    print(f"Counter: {adapter.counter} (expected: 10000)")
    assert adapter.counter == 10000, "Race condition detected!"
```

---

## Performance Optimization

### 1. NumPy/SciPy Optimization

NumPy operations release the GIL, enabling true parallelism:

```python
import numpy as np

@thread_safe_method
def matrix_multiply(self, data):
    # This releases GIL - true parallel execution!
    arr = np.array(data)
    result = np.dot(arr, self.weights)
    return result.tolist()
```

### 2. Thread Pool Sizing

```bash
# Rule of thumb: threads = CPU cores × 2
# For 8-core machine:
--max-workers 16
```

### 3. Reduce Lock Contention

```python
# BAD: Lock held during computation
with self.acquire_lock():
    result = expensive_computation()  # Blocks other threads!
    self.results.append(result)

# GOOD: Lock only for shared state update
result = expensive_computation()  # No lock - other threads run
with self.acquire_lock():
    self.results.append(result)  # Lock held briefly
```

### 4. Use Thread-Local Caching

```python
@thread_safe_method
def compute(self, key):
    # Check thread-local cache first (no lock!)
    cache = self.get_thread_local('cache', {})
    if key in cache:
        return cache[key]

    # Compute and cache
    result = expensive_function(key)
    cache[key] = result
    self.set_thread_local('cache', cache)

    return result
```

---

## Common Pitfalls

### Pitfall 1: Forgetting to Lock Shared State

```python
# ❌ WRONG: Race condition!
@thread_safe_method
def increment(self):
    self.counter += 1  # NOT thread-safe!

# ✅ CORRECT:
@thread_safe_method
def increment(self):
    with self.acquire_lock():
        self.counter += 1
```

### Pitfall 2: Locking Inside GIL-Releasing Operations

```python
# ❌ WRONG: Lock held during NumPy operation
with self.acquire_lock():
    result = np.dot(large_matrix_a, large_matrix_b)  # Blocks threads!

# ✅ CORRECT: Compute first, then lock for state update
result = np.dot(large_matrix_a, large_matrix_b)
with self.acquire_lock():
    self.results.append(result)
```

### Pitfall 3: Using Thread-Unsafe Libraries

```python
# ❌ WRONG: Pandas is NOT thread-safe
import pandas as pd

@thread_safe_method
def process_data(self, data):
    df = pd.DataFrame(data)
    return df.groupby('category').sum()  # Race conditions!

# ✅ CORRECT: Use thread-local DataFrames or locking
@thread_safe_method
def process_data(self, data):
    with self.acquire_lock():
        df = pd.DataFrame(data)
        return df.groupby('category').sum()
```

### Pitfall 4: Not Declaring Thread Safety

```python
# ❌ WRONG: Missing declaration
class MyAdapter(ThreadSafeAdapter):
    # __thread_safe__ not declared!
    pass

# ✅ CORRECT:
class MyAdapter(ThreadSafeAdapter):
    __thread_safe__ = True
```

---

## Library Compatibility

### Thread-Safe Libraries ✅

These libraries release the GIL and are safe for threaded mode:

| Library | Thread-Safe | Notes |
|---------|-------------|-------|
| **NumPy** | ✅ Yes | Releases GIL during computation |
| **SciPy** | ✅ Yes | Releases GIL for numerical operations |
| **PyTorch** | ✅ Yes | Configure with `torch.set_num_threads()` |
| **TensorFlow** | ✅ Yes | Use `tf.config.threading` API |
| **Scikit-learn** | ✅ Yes | Set `n_jobs=1` per estimator |
| **Requests** | ✅ Yes | Separate sessions per thread |
| **HTTPx** | ✅ Yes | Async-first, thread-safe |

### Thread-Unsafe Libraries ❌

These libraries require process mode or explicit locking:

| Library | Thread-Safe | Workaround |
|---------|-------------|------------|
| **Pandas** | ❌ No | Use locking or process mode |
| **Matplotlib** | ❌ No | Use `threading.local()` for figures |
| **SQLite3** | ❌ No | Connection per thread |

### Example: Thread-Safe PyTorch

```python
import torch

class PyTorchAdapter(ThreadSafeAdapter):
    __thread_safe__ = True

    def __init__(self):
        super().__init__()
        # Shared read-only model
        self.model = torch.load("model.pt")
        self.model.eval()

        # Configure threading
        torch.set_num_threads(4)  # Per-thread parallelism

    @thread_safe_method
    def inference(self, input_tensor):
        # PyTorch releases GIL during forward pass
        with torch.no_grad():
            output = self.model(torch.tensor(input_tensor))
        return output.tolist()
```

---

## Advanced Topics

### Worker Recycling

Long-running threaded workers can accumulate memory. Configure automatic recycling:

```elixir
config :snakepit,
  pools: [
    %{
      name: :hpc_pool,
      worker_profile: :thread,
      worker_ttl: {3600, :seconds},  # Recycle hourly
      worker_max_requests: 1000       # Or after 1000 requests
    }
  ]
```

### Monitoring Thread Utilization

```python
@thread_safe_method
def get_thread_stats(self):
    return self.get_stats()
```

```elixir
{:ok, stats} = Snakepit.execute(:hpc_pool, "get_thread_stats", %{})
# => %{
#   total_requests: 1234,
#   active_requests: 8,
#   max_workers: 16,
#   thread_utilization: %{...}
# }
```

---

## Debugging

### Enable Thread Safety Checks

```bash
python grpc_server_threaded.py \
    --thread-safety-check  # Enable runtime validation
```

### View Detailed Logs

```bash
# Logs show thread names
2025-10-11 10:30:45 - [ThreadPoolExecutor-0_0] - INFO - Request #1 starting
2025-10-11 10:30:45 - [ThreadPoolExecutor-0_1] - INFO - Request #2 starting
```

### Common Error Messages

```
⚠️  THREAD SAFETY: Method 'predict' accessed by 5 different threads concurrently.
```
**Solution:** Ensure proper locking for shared mutable state.

```
⚠️  Adapter MyAdapter does not declare thread safety.
```
**Solution:** Add `__thread_safe__ = True` to your adapter class.

```
⚠️  THREAD SAFETY: Unsafe library 'pandas' detected
```
**Solution:** Use process mode or add explicit locking.

---

## Summary

### Do's ✅
- Declare `__thread_safe__ = True`
- Use `@thread_safe_method` decorator
- Lock shared mutable state
- Use thread-local storage for caches
- Test with concurrent load
- Use NumPy/PyTorch for CPU-bound work

### Don'ts ❌
- Don't modify shared state without locking
- Don't use thread-unsafe libraries without protection
- Don't hold locks during expensive operations
- Don't forget to test concurrent access
- Don't use threaded mode with Python ≤3.12

---

## Resources

- [PEP 703: Making the GIL Optional](https://peps.python.org/pep-0703/)
- [Python 3.13 Free-Threading Docs](https://docs.python.org/3.13/howto/free-threading-python.html)
- Snakepit v0.7.4 Technical Plan (see project documentation)
- [Thread Safety Compatibility Matrix](../../lib/snakepit/compatibility.ex)

---

**Need Help?**
- Check existing examples in `snakepit_bridge/adapters/threaded_showcase.py`
- Run thread safety checker with `--thread-safety-check`
- Review logs for concurrent access warnings
- Test with multiple concurrent requests before deployment
