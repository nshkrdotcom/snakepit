"""
Thread-safe base adapter for multi-threaded gRPC workers.

This module provides base classes for adapters that need to handle
concurrent requests in a multi-threaded environment (Python 3.13+ free-threading).

Key Features:
- Thread-safe request handling
- Thread-local storage support
- Automatic locking for critical sections
- Request tracking per thread
- Thread safety validation

Usage:
    from snakepit_bridge.base_adapter_threaded import ThreadSafeAdapter, thread_safe_method

    class MyAdapter(ThreadSafeAdapter):
        __thread_safe__ = True  # Declare thread safety

        def __init__(self):
            super().__init__()
            self.model = load_model()  # Shared read-only

        @thread_safe_method
        def execute_tool(self, tool_name, arguments, context):
            # This method is automatically tracked and protected
            return self._process_request(arguments)
"""

import threading
import logging
import time
import functools
from typing import Any, Dict, Optional, Callable
from contextlib import contextmanager
from collections import defaultdict

from snakepit_bridge.base_adapter import BaseAdapter, tool, ToolMetadata

logger = logging.getLogger(__name__)


class ThreadLocalStorage:
    """
    Thread-local storage manager for adapter state.

    Provides isolated storage per thread, useful for:
    - Caches that don't need cross-thread sharing
    - Per-request temporary data
    - Thread-specific configurations
    """

    def __init__(self):
        self._storage = threading.local()

    def get(self, key: str, default=None):
        """Get thread-local value"""
        return getattr(self._storage, key, default)

    def set(self, key: str, value: Any):
        """Set thread-local value"""
        setattr(self._storage, key, value)

    def delete(self, key: str):
        """Delete thread-local value"""
        try:
            delattr(self._storage, key)
        except AttributeError:
            pass

    def clear(self):
        """Clear all thread-local values"""
        self._storage.__dict__.clear()


class RequestTracker:
    """
    Track requests across threads for monitoring and debugging.

    Records:
    - Request count per thread
    - Active requests
    - Request duration
    - Concurrent access patterns
    """

    def __init__(self):
        self.requests_by_thread: Dict[int, int] = defaultdict(int)
        self.active_requests: Dict[int, int] = defaultdict(int)
        self.total_requests = 0
        self.lock = threading.Lock()

    def start_request(self, thread_id: Optional[int] = None) -> int:
        """Mark request start, return request ID"""
        if thread_id is None:
            thread_id = threading.get_ident()

        with self.lock:
            self.total_requests += 1
            request_id = self.total_requests
            self.requests_by_thread[thread_id] += 1
            self.active_requests[thread_id] += 1
            return request_id

    def end_request(self, thread_id: Optional[int] = None):
        """Mark request end"""
        if thread_id is None:
            thread_id = threading.get_ident()

        with self.lock:
            if self.active_requests[thread_id] > 0:
                self.active_requests[thread_id] -= 1

    def get_stats(self) -> dict:
        """Get tracking statistics"""
        with self.lock:
            return {
                "total_requests": self.total_requests,
                "active_threads": len([c for c in self.active_requests.values() if c > 0]),
                "total_active_requests": sum(self.active_requests.values()),
                "threads_seen": len(self.requests_by_thread)
            }


def thread_safe_method(func: Callable) -> Callable:
    """
    Decorator to mark and track thread-safe methods.

    Automatically adds:
    - Request tracking
    - Execution timing
    - Thread identification logging
    - Exception handling

    Usage:
        @thread_safe_method
        def my_method(self, arg):
            return process(arg)
    """
    @functools.wraps(func)
    def wrapper(self, *args, **kwargs):
        if not isinstance(self, ThreadSafeAdapter):
            # Not a ThreadSafeAdapter, just call normally
            return func(self, *args, **kwargs)

        thread_id = threading.get_ident()
        thread_name = threading.current_thread().name
        request_id = self._tracker.start_request(thread_id)

        start_time = time.time()
        logger.debug(f"[{thread_name}] Request #{request_id} starting: {func.__name__}")

        try:
            result = func(self, *args, **kwargs)
            duration = time.time() - start_time
            logger.debug(f"[{thread_name}] Request #{request_id} completed in {duration:.3f}s")
            return result

        except Exception as e:
            duration = time.time() - start_time
            logger.error(
                f"[{thread_name}] Request #{request_id} failed after {duration:.3f}s: {e}",
                exc_info=True
            )
            raise

        finally:
            self._tracker.end_request(thread_id)

    # Mark as thread-safe
    wrapper.__thread_safe__ = True
    return wrapper


class ThreadSafeAdapter(BaseAdapter):
    """
    Base class for thread-safe adapters.

    Provides infrastructure for building adapters that can safely handle
    concurrent requests in a multi-threaded environment.

    Thread Safety Patterns:
    1. **Shared Read-Only**: Load once, read from many threads
    2. **Thread-Local**: Per-thread isolated state
    3. **Locked Writes**: Protect shared mutable state

    Example:
        class MyAdapter(ThreadSafeAdapter):
            __thread_safe__ = True

            def __init__(self):
                super().__init__()
                # Pattern 1: Shared read-only
                self.model = load_model()

            @thread_safe_method
            def execute_tool(self, tool_name, arguments, context):
                # Pattern 2: Thread-local cache
                cache = self.get_thread_local('cache', {})

                # Use shared read-only resource
                prediction = self.model.predict(arguments['input'])

                # Pattern 3: Write to shared state with lock
                with self.acquire_lock():
                    self.request_log.append(prediction)

                return prediction
    """

    __thread_safe__ = True  # Marker for thread safety validation

    def __init__(self):
        super().__init__()

        # Thread safety infrastructure
        self._lock = threading.RLock()  # Reentrant lock
        self._thread_local = ThreadLocalStorage()
        self._tracker = RequestTracker()

        logger.debug(f"Initialized thread-safe adapter: {self.__class__.__name__}")

    # Thread Safety API

    @contextmanager
    def acquire_lock(self):
        """
        Acquire the adapter's global lock for critical sections.

        Use this when you need to protect shared mutable state.

        Example:
            with self.acquire_lock():
                self.shared_counter += 1
        """
        self._lock.acquire()
        try:
            yield
        finally:
            self._lock.release()

    def get_thread_local(self, key: str, default=None) -> Any:
        """
        Get a thread-local value.

        Thread-local storage is isolated per thread, useful for caches
        or temporary state that doesn't need cross-thread sharing.

        Args:
            key: Storage key
            default: Default value if not set

        Returns:
            Thread-local value or default
        """
        return self._thread_local.get(key, default)

    def set_thread_local(self, key: str, value: Any):
        """
        Set a thread-local value.

        Args:
            key: Storage key
            value: Value to store
        """
        self._thread_local.set(key, value)

    def clear_thread_local(self, key: Optional[str] = None):
        """
        Clear thread-local storage.

        Args:
            key: Specific key to clear, or None to clear all
        """
        if key is None:
            self._thread_local.clear()
        else:
            self._thread_local.delete(key)

    def get_stats(self) -> dict:
        """
        Get adapter statistics.

        Returns dict with:
        - Request counts
        - Active threads
        - Thread utilization
        """
        return {
            "adapter_class": self.__class__.__name__,
            "thread_safe": self.__thread_safe__,
            "tracker": self._tracker.get_stats()
        }

    # Context manager for request tracking

    @contextmanager
    def track_request(self, request_id: Optional[str] = None):
        """
        Context manager for explicit request tracking.

        Usage:
            with self.track_request(request_id="my-request"):
                result = do_work()
        """
        req_id = self._tracker.start_request()
        try:
            yield req_id
        finally:
            self._tracker.end_request()


# Utility decorators and functions

def require_thread_safe(func: Callable) -> Callable:
    """
    Decorator to enforce that an adapter is thread-safe.

    Raises ValueError if adapter doesn't declare thread safety.

    Usage:
        @require_thread_safe
        def handle_concurrent_requests(adapter, requests):
            for req in requests:
                adapter.execute_tool(req)
    """
    @functools.wraps(func)
    def wrapper(adapter, *args, **kwargs):
        if not hasattr(adapter, '__thread_safe__') or not adapter.__thread_safe__:
            raise ValueError(
                f"Adapter {adapter.__class__.__name__} is not thread-safe. "
                f"Set __thread_safe__ = True if adapter supports concurrent access."
            )
        return func(adapter, *args, **kwargs)
    return wrapper


def validate_thread_safety(adapter_class: type) -> bool:
    """
    Validate that an adapter declares thread safety.

    Args:
        adapter_class: Adapter class to check

    Returns:
        True if thread-safe, False otherwise
    """
    return (
        hasattr(adapter_class, '__thread_safe__') and
        adapter_class.__thread_safe__ is True
    )


# Example adapter demonstrating patterns

class ExampleThreadSafeAdapter(ThreadSafeAdapter):
    """
    Example adapter showing thread-safe patterns.

    Demonstrates:
    1. Shared read-only resources
    2. Thread-local caching
    3. Locked writes to shared state
    """

    __thread_safe__ = True

    def __init__(self):
        super().__init__()

        # Pattern 1: Shared read-only (loaded once, read by all threads)
        # This is safe because it's never modified after initialization
        self.config = {"model_name": "example", "version": "1.0"}

        # Pattern 3: Shared mutable state (requires locking)
        # This will be modified, so we need the lock
        self.request_log = []
        self.total_predictions = 0

    @thread_safe_method
    @tool(description="Make a prediction", supports_streaming=False)
    def predict(self, input_data: str) -> dict:
        """
        Thread-safe prediction method.

        Shows all three patterns:
        - Reading shared config (no lock needed)
        - Using thread-local cache
        - Writing to shared log (with lock)
        """
        # Pattern 1: Read shared config (no lock needed - read-only)
        model_name = self.config["model_name"]

        # Pattern 2: Thread-local cache
        cache = self.get_thread_local('predictions_cache', {})

        if input_data in cache:
            logger.debug(f"Cache hit for {input_data}")
            return cache[input_data]

        # Simulate prediction
        result = {
            "input": input_data,
            "model": model_name,
            "prediction": f"result_for_{input_data}",
            "thread": threading.current_thread().name
        }

        # Update thread-local cache
        cache[input_data] = result
        self.set_thread_local('predictions_cache', cache)

        # Pattern 3: Write to shared state (MUST use lock)
        with self.acquire_lock():
            self.request_log.append({
                "input": input_data,
                "timestamp": time.time(),
                "thread": threading.current_thread().name
            })
            self.total_predictions += 1

        return result

    @thread_safe_method
    @tool(description="Get adapter statistics")
    def get_statistics(self) -> dict:
        """Get thread-safe statistics"""
        with self.acquire_lock():
            return {
                "total_predictions": self.total_predictions,
                "log_size": len(self.request_log),
                **self.get_stats()
            }
