# Writing Thread-Safe Adapters for Snakepit

**Guide Version**: 1.0
**Date**: 2025-10-11
**Snakepit Version**: v0.6.0+

---

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Thread Safety Fundamentals](#thread-safety-fundamentals)
4. [Three Safety Patterns](#three-safety-patterns)
5. [Step-by-Step Tutorial](#step-by-step-tutorial)
6. [Common Pitfalls](#common-pitfalls)
7. [Testing Strategies](#testing-strategies)
8. [Library Compatibility](#library-compatibility)
9. [Advanced Topics](#advanced-topics)
10. [Debugging Guide](#debugging-guide)
11. [Best Practices](#best-practices)
12. [Examples](#examples)

---

## Overview

### What is a Thread-Safe Adapter?

A thread-safe adapter can handle multiple concurrent requests without data corruption, race conditions, or undefined behavior. This guide teaches you how to write Python adapters that work correctly with Snakepit's multi-threaded worker profile.

### Why Thread Safety Matters

```python
# ❌ NOT thread-safe
class UnsafeAdapter:
    def __init__(self):
        self.counter = 0

    def process(self, data):
        self.counter += 1  # RACE CONDITION!
        return {"count": self.counter}

# ✅ Thread-safe
class SafeAdapter(ThreadSafeAdapter):
    def __init__(self):
        super().__init__()
        self.counter = 0

    def process(self, data):
        with self.acquire_lock():
            self.counter += 1
            return {"count": self.counter}
```

### When You Need This Guide

- ✅ Building custom Python adapters for Snakepit
- ✅ Using thread worker profile (`:thread`)
- ✅ Python 3.13+ with free-threading enabled
- ✅ CPU-intensive workloads requiring parallelism

---

## Prerequisites

### Required Knowledge

- **Python**: Functions, classes, decorators
- **Concurrency**: Basic understanding of threads
- **Snakepit**: Adapter pattern, worker profiles

### Required Software

```bash
# Python 3.13+ with free-threading
python3.13 --version
# => Python 3.13.0

# Verify free-threading support
python3.13 -c "import sys; print(hasattr(sys, '_is_gil_enabled'))"
# => True

# Snakepit v0.6.0+
mix deps | grep snakepit
# => * snakepit 0.6.0
```

### Test Environment Setup

```bash
# Create virtual environment
python3.13 -m venv .venv
source .venv/bin/activate

# Install dependencies
pip install grpcio protobuf numpy pytest pytest-xdist

# Install Snakepit Python bridge
pip install -e deps/snakepit/priv/python
```

---

## Thread Safety Fundamentals

### The Three Rules of Thread Safety

1. **Immutable shared state is safe**
   - Read-only data can be accessed concurrently
   - Examples: Pre-loaded models, config dicts

2. **Mutable shared state requires locking**
   - If data can be modified, protect with locks
   - Examples: Counters, logs, caches

3. **Thread-local storage is safe**
   - Data isolated per thread doesn't need locks
   - Examples: Per-thread caches, buffers

### Thread Safety Checklist

When reviewing your adapter, ask:

- [ ] Does this method modify shared state?
- [ ] Is this data structure accessed from multiple threads?
- [ ] Does this library release the GIL?
- [ ] Are there any race conditions?
- [ ] Is error handling thread-safe?

---

## Three Safety Patterns

### Pattern 1: Shared Read-Only Resources

**When to use**: Data loaded once, never modified

```python
from snakepit_bridge.base_adapter_threaded import ThreadSafeAdapter

class ModelAdapter(ThreadSafeAdapter):
    __thread_safe__ = True  # Required declaration

    def __init__(self):
        super().__init__()

        # Pattern 1: Shared read-only (NO LOCK NEEDED)
        self.model = self._load_model()
        self.config = {"timeout": 30, "batch_size": 10}

    def _load_model(self):
        """Load model once, shared across threads"""
        import torch
        model = torch.load("model.pt")
        model.eval()  # Set to evaluation mode
        return model

    @thread_safe_method
    def predict(self, input_data):
        # Safe: model is read-only
        # PyTorch releases GIL during forward pass
        with torch.no_grad():
            output = self.model(torch.tensor(input_data))
        return output.tolist()
```

**Why it's safe**:
- Model loaded once in `__init__`
- Never modified after loading
- PyTorch `.forward()` releases GIL
- Multiple threads can read concurrently

### Pattern 2: Thread-Local Storage

**When to use**: Per-thread state (caches, buffers, connections)

```python
class CachingAdapter(ThreadSafeAdapter):
    __thread_safe__ = True

    def __init__(self):
        super().__init__()
        self.model = load_model()  # Shared read-only

    @thread_safe_method
    def compute(self, key, data):
        # Pattern 2: Thread-local storage (NO LOCK NEEDED)

        # Each thread has its own cache
        cache = self.get_thread_local('cache', {})

        if key in cache:
            return cache[key]

        # Compute result
        result = self.model.predict(data)

        # Update thread-local cache
        cache[key] = result
        self.set_thread_local('cache', cache)

        return result
```

**Why it's safe**:
- Each thread has isolated `cache` dict
- No sharing between threads
- No race conditions possible
- Excellent performance (no locks)

### Pattern 3: Locked Shared Mutable State

**When to use**: State that must be shared AND modified

```python
class CountingAdapter(ThreadSafeAdapter):
    __thread_safe__ = True

    def __init__(self):
        super().__init__()
        self.model = load_model()  # Pattern 1

        # Pattern 3: Shared mutable (REQUIRES LOCK)
        self.total_requests = 0
        self.request_log = []

    @thread_safe_method
    def process(self, data):
        # Compute first (NO LOCK - allows parallelism)
        result = self.model.predict(data)

        # THEN lock for state update (BRIEF LOCK)
        with self.acquire_lock():
            self.total_requests += 1
            self.request_log.append({
                "result": result,
                "timestamp": time.time()
            })

        return result

    @thread_safe_method
    def get_stats(self):
        # Pattern 3: Read shared mutable (REQUIRES LOCK)
        with self.acquire_lock():
            return {
                "total_requests": self.total_requests,
                "log_size": len(self.request_log)
            }
```

**Why it's safe**:
- Compute happens WITHOUT lock (parallel)
- Lock held only for state update (fast)
- Both reads and writes protected
- No race conditions

---

## Step-by-Step Tutorial

### Step 1: Create Thread-Safe Adapter Class

```python
# my_adapter.py
from snakepit_bridge.base_adapter_threaded import (
    ThreadSafeAdapter,
    thread_safe_method,
    tool
)
import numpy as np

class MyAdapter(ThreadSafeAdapter):
    """Example thread-safe adapter"""

    # Step 1.1: Declare thread safety
    __thread_safe__ = True

    def __init__(self):
        # Step 1.2: Call parent constructor
        super().__init__()

        # Step 1.3: Initialize resources
        # Pattern 1: Shared read-only
        self.model = self._load_model()

        # Pattern 3: Shared mutable
        self.request_count = 0
```

### Step 2: Implement Thread-Safe Methods

```python
    @thread_safe_method
    @tool(description="Compute with NumPy")
    def compute(self, data: list) -> dict:
        """
        Thread-safe computation.

        Uses Pattern 1 (shared model) + Pattern 3 (shared counter).
        """
        # Convert to NumPy array (thread-safe)
        arr = np.array(data)

        # NumPy computation (releases GIL - parallel!)
        result = np.dot(arr, arr.T)

        # Update shared state (lock required)
        with self.acquire_lock():
            self.request_count += 1
            count = self.request_count

        return {
            "result": result.tolist(),
            "request_number": count
        }
```

### Step 3: Add Thread-Local Caching

```python
    @thread_safe_method
    @tool(description="Compute with caching")
    def compute_cached(self, key: str, data: list) -> dict:
        """
        Thread-safe computation with per-thread cache.

        Uses Pattern 2 (thread-local storage).
        """
        # Check thread-local cache first
        cache = self.get_thread_local('cache', {})

        if key in cache:
            return {
                "result": cache[key],
                "cached": True
            }

        # Compute
        arr = np.array(data)
        result = np.dot(arr, arr.T).tolist()

        # Update thread-local cache
        cache[key] = result
        self.set_thread_local('cache', cache)

        # Update shared counter
        with self.acquire_lock():
            self.request_count += 1

        return {
            "result": result,
            "cached": False
        }
```

### Step 4: Add Statistics Method

```python
    @thread_safe_method
    @tool(description="Get adapter statistics")
    def get_stats(self) -> dict:
        """
        Thread-safe statistics.

        Reads shared mutable state (Pattern 3).
        """
        with self.acquire_lock():
            stats = self.get_stats_dict()
            stats['total_requests'] = self.request_count

        return stats
```

### Step 5: Test Thread Safety

```python
# test_my_adapter.py
import pytest
import threading
from concurrent.futures import ThreadPoolExecutor

def test_concurrent_compute(my_adapter):
    """Test concurrent access to compute method"""

    results = []
    errors = []

    def make_request(i):
        try:
            result = my_adapter.compute([1, 2, 3, 4, 5])
            results.append(result)
        except Exception as e:
            errors.append(e)

    # Hammer with 100 concurrent requests
    with ThreadPoolExecutor(max_workers=20) as executor:
        futures = [executor.submit(make_request, i) for i in range(100)]
        for future in futures:
            future.result(timeout=10)

    # All should succeed
    assert len(results) == 100
    assert len(errors) == 0

    # Request count should be exactly 100
    stats = my_adapter.get_stats()
    assert stats['total_requests'] == 100
```

---

## Common Pitfalls

### Pitfall 1: Forgetting to Lock Shared State

```python
# ❌ WRONG: Race condition
class BadAdapter(ThreadSafeAdapter):
    def __init__(self):
        super().__init__()
        self.counter = 0

    @thread_safe_method
    def increment(self):
        self.counter += 1  # NOT ATOMIC!
        return self.counter

# ✅ CORRECT: Lock protected
class GoodAdapter(ThreadSafeAdapter):
    def __init__(self):
        super().__init__()
        self.counter = 0

    @thread_safe_method
    def increment(self):
        with self.acquire_lock():
            self.counter += 1
            return self.counter
```

**Problem**: `self.counter += 1` is three operations:
1. Read `self.counter`
2. Add 1
3. Write back

Between steps 1-3, another thread can modify `counter`.

### Pitfall 2: Holding Lock During Expensive Operations

```python
# ❌ WRONG: Lock held during computation
@thread_safe_method
def process(self, data):
    with self.acquire_lock():
        arr = np.array(data)
        result = np.dot(arr, arr.T)  # EXPENSIVE!
        self.results.append(result)
    return result

# ✅ CORRECT: Minimize lock duration
@thread_safe_method
def process(self, data):
    # Compute WITHOUT lock
    arr = np.array(data)
    result = np.dot(arr, arr.T)

    # THEN lock briefly
    with self.acquire_lock():
        self.results.append(result)

    return result
```

**Rule**: Only hold locks for the minimum time needed.

### Pitfall 3: Using Thread-Unsafe Libraries

```python
# ❌ WRONG: Pandas is NOT thread-safe
import pandas as pd

class BadAdapter(ThreadSafeAdapter):
    def __init__(self):
        super().__init__()
        self.df = pd.DataFrame()  # Shared DataFrame

    @thread_safe_method
    def add_row(self, data):
        # RACE CONDITION! Even with lock around DataFrame
        self.df = self.df.append(data, ignore_index=True)

# ✅ CORRECT: Use thread-safe alternatives
import polars as pl

class GoodAdapter(ThreadSafeAdapter):
    def __init__(self):
        super().__init__()
        self.rows = []  # Collect rows

    @thread_safe_method
    def add_row(self, data):
        with self.acquire_lock():
            self.rows.append(data)

    @thread_safe_method
    def get_dataframe(self):
        with self.acquire_lock():
            return pl.DataFrame(self.rows)
```

**Solution**: Use Polars instead of Pandas, or lock ALL DataFrame operations.

### Pitfall 4: Missing __thread_safe__ Declaration

```python
# ❌ WRONG: No declaration
class BadAdapter(ThreadSafeAdapter):
    # Missing __thread_safe__ = True

# ✅ CORRECT: Always declare
class GoodAdapter(ThreadSafeAdapter):
    __thread_safe__ = True
```

**Why**: Runtime checker validates thread safety when declared.

### Pitfall 5: Deadlocks

```python
# ❌ WRONG: Potential deadlock
@thread_safe_method
def method_a(self):
    with self.acquire_lock():
        return self.method_b()  # Tries to acquire same lock!

@thread_safe_method
def method_b(self):
    with self.acquire_lock():
        return "result"

# ✅ CORRECT: Use reentrant lock (already provided)
# ThreadSafeAdapter uses RLock (reentrant), so this works:

@thread_safe_method
def method_a(self):
    with self.acquire_lock():
        return self._method_b_impl()

def _method_b_impl(self):
    # Private method, called within lock
    return "result"
```

---

## Testing Strategies

### Strategy 1: Concurrent Hammer Test

```python
def test_concurrent_hammer():
    adapter = MyAdapter()
    results = []

    def worker(i):
        for _ in range(100):
            result = adapter.compute([i, i+1, i+2])
            results.append(result)

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(10)]

    for t in threads:
        t.start()
    for t in threads:
        t.join()

    # Should have exactly 1000 results
    assert len(results) == 1000

    # Counter should be exactly 1000
    stats = adapter.get_stats()
    assert stats['total_requests'] == 1000
```

### Strategy 2: Race Condition Detector

```python
def test_race_condition():
    """
    If increment has race condition, final count will be < 10000
    """
    adapter = MyAdapter()

    def increment_many():
        for _ in range(1000):
            adapter.increment()

    threads = [threading.Thread(target=increment_many) for _ in range(10)]

    for t in threads:
        t.start()
    for t in threads:
        t.join()

    # If thread-safe, count should be exactly 10000
    assert adapter.get_count() == 10000
```

### Strategy 3: Thread Safety Checker

```python
from snakepit_bridge.thread_safety_checker import ThreadSafetyChecker

def test_with_checker():
    checker = ThreadSafetyChecker(enabled=True, strict_mode=True)

    adapter = MyAdapter()

    # Run concurrent requests
    def worker():
        for _ in range(50):
            adapter.compute([1, 2, 3])

    threads = [threading.Thread(target=worker) for _ in range(20)]

    for t in threads:
        t.start()
    for t in threads:
        t.join()

    # Get thread safety report
    report = checker.get_report()

    # Should have no warnings
    assert len(report['warnings']) == 0
```

### Strategy 4: Load Testing

```python
import pytest
from concurrent.futures import ThreadPoolExecutor

@pytest.mark.benchmark
def test_throughput():
    adapter = MyAdapter()

    def single_request():
        return adapter.compute([1, 2, 3, 4, 5])

    # Measure throughput
    with ThreadPoolExecutor(max_workers=16) as executor:
        start = time.time()

        futures = [executor.submit(single_request) for _ in range(1000)]
        results = [f.result() for f in futures]

        elapsed = time.time() - start

    throughput = 1000 / elapsed
    print(f"Throughput: {throughput:.2f} req/s")

    # All requests should succeed
    assert len(results) == 1000
```

---

## Library Compatibility

### Thread-Safe Libraries ✅

These libraries work well with threaded adapters:

| Library | Thread-Safe | Notes |
|---------|-------------|-------|
| **NumPy** | ✅ Yes | Releases GIL during computation |
| **SciPy** | ✅ Yes | Releases GIL for numerical ops |
| **PyTorch** | ✅ Yes | Configure with `torch.set_num_threads()` |
| **TensorFlow** | ✅ Yes | Use `tf.config.threading` |
| **Scikit-learn** | ✅ Yes | Set `n_jobs=1` per estimator |
| **Polars** | ✅ Yes | Thread-safe DataFrame library |
| **HTTPx** | ✅ Yes | Async-first, thread-safe |
| **Requests** | ✅ Yes | Use separate Session per thread |

### Thread-Unsafe Libraries ❌

These require special handling:

| Library | Thread-Safe | Workaround |
|---------|-------------|------------|
| **Pandas** | ❌ No | Use Polars or lock all DataFrame ops |
| **Matplotlib** | ❌ No | Use `threading.local()` for figures |
| **SQLite3** | ❌ No | Connection per thread with `check_same_thread=False` |

### Example: Thread-Safe NumPy

```python
class NumPyAdapter(ThreadSafeAdapter):
    __thread_safe__ = True

    @thread_safe_method
    def matrix_multiply(self, a_data, b_data):
        # NumPy releases GIL - true parallelism!
        a = np.array(a_data)
        b = np.array(b_data)
        result = np.dot(a, b)
        return result.tolist()
```

### Example: Thread-Safe PyTorch

```python
import torch

class TorchAdapter(ThreadSafeAdapter):
    __thread_safe__ = True

    def __init__(self):
        super().__init__()

        # Load model once (shared read-only)
        self.model = torch.load("model.pt")
        self.model.eval()

        # Configure threading
        torch.set_num_threads(4)

    @thread_safe_method
    def inference(self, input_data):
        # PyTorch releases GIL during forward
        with torch.no_grad():
            tensor = torch.tensor(input_data)
            output = self.model(tensor)
        return output.tolist()
```

### Example: Workaround for Pandas

```python
import pandas as pd

class PandasAdapter(ThreadSafeAdapter):
    __thread_safe__ = True

    @thread_safe_method
    def process_dataframe(self, data):
        # Lock ALL Pandas operations
        with self.acquire_lock():
            df = pd.DataFrame(data)
            result = df.groupby('category').sum()
            return result.to_dict()
```

---

## Advanced Topics

### Topic 1: Custom Locks

```python
class MultiLockAdapter(ThreadSafeAdapter):
    __thread_safe__ = True

    def __init__(self):
        super().__init__()

        # Use separate locks for different resources
        import threading
        self.counter_lock = threading.Lock()
        self.log_lock = threading.Lock()

        self.counter = 0
        self.log = []

    @thread_safe_method
    def increment(self):
        with self.counter_lock:  # Only locks counter
            self.counter += 1

    @thread_safe_method
    def log_event(self, event):
        with self.log_lock:  # Only locks log
            self.log.append(event)
```

**When to use**: Reduce contention by using separate locks for independent resources.

### Topic 2: Lock-Free Data Structures

```python
from queue import Queue  # Thread-safe queue

class QueueAdapter(ThreadSafeAdapter):
    __thread_safe__ = True

    def __init__(self):
        super().__init__()
        self.results = Queue()  # Lock-free!

    @thread_safe_method
    def add_result(self, result):
        self.results.put(result)  # Thread-safe, no lock needed

    @thread_safe_method
    def get_results(self):
        results = []
        while not self.results.empty():
            results.append(self.results.get())
        return results
```

### Topic 3: Atomic Operations

```python
import threading

class AtomicAdapter(ThreadSafeAdapter):
    __thread_safe__ = True

    def __init__(self):
        super().__init__()
        self.counter = 0
        self._lock = threading.Lock()

    @thread_safe_method
    def atomic_increment(self):
        # More efficient than context manager for simple ops
        self._lock.acquire()
        try:
            self.counter += 1
            result = self.counter
        finally:
            self._lock.release()
        return result
```

---

## Debugging Guide

### Enable Thread Safety Checks

```bash
python grpc_server_threaded.py \
    --thread-safety-check  # Enable runtime validation
```

### Common Error Messages

#### Error: "Method accessed by multiple threads"

```
⚠️  THREAD SAFETY: Method 'predict' accessed by 5 different threads concurrently.
```

**Cause**: Method modifies shared state without locking.

**Solution**: Add lock around shared state access.

#### Error: "Unsafe library detected"

```
⚠️  THREAD SAFETY: Unsafe library 'pandas' detected
```

**Cause**: Using thread-unsafe library.

**Solution**: Switch to thread-safe alternative or add locking.

#### Error: "Adapter does not declare thread safety"

```
⚠️  Adapter MyAdapter does not declare thread safety.
```

**Cause**: Missing `__thread_safe__ = True`.

**Solution**: Add declaration to adapter class.

### Debugging Tools

```python
# Enable detailed logging
import logging
logging.basicConfig(level=logging.DEBUG)

# Check which thread is running
import threading
print(f"Thread: {threading.current_thread().name}")

# Track lock acquisitions
class DebugAdapter(ThreadSafeAdapter):
    @thread_safe_method
    def compute(self, data):
        print(f"[{threading.current_thread().name}] Acquiring lock...")
        with self.acquire_lock():
            print(f"[{threading.current_thread().name}] Lock acquired!")
            result = do_work(data)
        print(f"[{threading.current_thread().name}] Lock released")
        return result
```

---

## Best Practices

### Do's ✅

1. **Always declare thread safety**
   ```python
   class MyAdapter(ThreadSafeAdapter):
       __thread_safe__ = True
   ```

2. **Use `@thread_safe_method` decorator**
   ```python
   @thread_safe_method
   def my_method(self):
       ...
   ```

3. **Minimize lock duration**
   ```python
   # Compute first
   result = expensive_operation()

   # THEN lock
   with self.acquire_lock():
       self.results.append(result)
   ```

4. **Use thread-local storage for caches**
   ```python
   cache = self.get_thread_local('cache', {})
   ```

5. **Test with concurrent load**
   ```python
   ThreadPoolExecutor(max_workers=20)
   ```

### Don'ts ❌

1. **Don't modify shared state without locking**
   ```python
   # ❌ WRONG
   self.counter += 1
   ```

2. **Don't use thread-unsafe libraries carelessly**
   ```python
   # ❌ WRONG
   self.df = self.df.append(row)  # Pandas
   ```

3. **Don't hold locks during I/O**
   ```python
   # ❌ WRONG
   with self.acquire_lock():
       requests.get(url)  # Blocks other threads!
   ```

4. **Don't nest locks (unless reentrant)**
   ```python
   # ⚠️  CAREFUL
   with lock_a:
       with lock_b:  # Potential deadlock
           ...
   ```

5. **Don't skip testing**
   ```python
   # ❌ WRONG
   # No concurrent tests = hidden race conditions
   ```

---

## Examples

### Example 1: Simple Counter Adapter

```python
from snakepit_bridge.base_adapter_threaded import ThreadSafeAdapter, thread_safe_method, tool

class CounterAdapter(ThreadSafeAdapter):
    __thread_safe__ = True

    def __init__(self):
        super().__init__()
        self.count = 0

    @thread_safe_method
    @tool(description="Increment counter")
    def increment(self) -> dict:
        with self.acquire_lock():
            self.count += 1
            return {"count": self.count}

    @thread_safe_method
    @tool(description="Get current count")
    def get_count(self) -> dict:
        with self.acquire_lock():
            return {"count": self.count}
```

### Example 2: ML Model Adapter with Caching

```python
import numpy as np
import torch

class MLAdapter(ThreadSafeAdapter):
    __thread_safe__ = True

    def __init__(self):
        super().__init__()

        # Pattern 1: Shared read-only
        self.model = torch.load("model.pt")
        self.model.eval()

        # Pattern 3: Shared mutable
        self.total_predictions = 0

    @thread_safe_method
    @tool(description="ML inference with caching")
    def predict(self, input_data: list, cache_key: str = None) -> dict:
        # Pattern 2: Thread-local cache
        if cache_key:
            cache = self.get_thread_local('cache', {})
            if cache_key in cache:
                return {"prediction": cache[cache_key], "cached": True}

        # Compute (NO LOCK - parallel!)
        tensor = torch.tensor(input_data)
        with torch.no_grad():
            output = self.model(tensor)
        prediction = output.tolist()

        # Update cache (thread-local, no lock needed)
        if cache_key:
            cache[cache_key] = prediction
            self.set_thread_local('cache', cache)

        # Update counter (shared, lock needed)
        with self.acquire_lock():
            self.total_predictions += 1

        return {"prediction": prediction, "cached": False}

    @thread_safe_method
    @tool(description="Get adapter statistics")
    def get_stats(self) -> dict:
        with self.acquire_lock():
            stats = self.get_stats_dict()
            stats['total_predictions'] = self.total_predictions

        return stats
```

### Example 3: Full Production Adapter

See `/priv/python/snakepit_bridge/adapters/threaded_showcase.py` for a comprehensive 400-line example demonstrating all three safety patterns.

---

## Summary

### Key Takeaways

1. **Three Patterns**: Read-only, thread-local, locked mutable
2. **Minimize Locks**: Compute without locks, lock only for updates
3. **Declare Safety**: Always add `__thread_safe__ = True`
4. **Test Concurrently**: Use ThreadPoolExecutor with 20+ workers
5. **Check Libraries**: Use thread-safe libraries (NumPy, PyTorch, Polars)

### Checklist for Thread-Safe Adapters

- [ ] Inherits from `ThreadSafeAdapter`
- [ ] Has `__thread_safe__ = True` declaration
- [ ] Uses `@thread_safe_method` on all public methods
- [ ] Shared mutable state protected with locks
- [ ] Lock duration minimized
- [ ] Thread-local storage used for caches
- [ ] Only thread-safe libraries used (or properly locked)
- [ ] Tested with concurrent requests (100+)
- [ ] Thread safety checker passes
- [ ] No race conditions or deadlocks

### Next Steps

1. **Read**: [README_THREADING.md](/priv/python/README_THREADING.md)
2. **Study**: [threaded_showcase.py](/priv/python/snakepit_bridge/adapters/threaded_showcase.py)
3. **Test**: [test_thread_safety.py](/tests/test_thread_safety.py)
4. **Deploy**: Production deployment guide (coming soon)

---

**Questions?** Open an issue or check the [FAQ in Migration Guide](/docs/migration_v0.5_to_v0.6.md#faq).
