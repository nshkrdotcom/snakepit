"""
Threaded Showcase Adapter - Demonstrates thread-safe patterns for concurrent execution.

This adapter showcases best practices for writing thread-safe adapters that can
handle multiple concurrent requests in Python 3.13+ free-threading mode.

Key Demonstrations:
1. Shared read-only resources (models, configurations)
2. Thread-local storage for per-thread caching
3. Locked access to shared mutable state
4. CPU-intensive operations that benefit from parallelism
5. Safe integration with ML libraries (NumPy, etc.)

Usage:
    # Start with threaded server
    python grpc_server_threaded.py \
        --port 50052 \
        --adapter snakepit_bridge.adapters.threaded_showcase.ThreadedShowcaseAdapter \
        --elixir-address localhost:50051 \
        --max-workers 16

    # From Elixir
    {:ok, result} = Snakepit.execute(:hpc_pool, "compute_intensive", %{data: [1,2,3]})
"""

import threading
import time
import random
import hashlib
import logging
from typing import List, Dict, Any, Optional
from dataclasses import dataclass

from snakepit_bridge.base_adapter_threaded import ThreadSafeAdapter, thread_safe_method, tool

logger = logging.getLogger(__name__)

# Try to import NumPy for realistic CPU-bound operations
try:
    import numpy as np
    NUMPY_AVAILABLE = True
except ImportError:
    NUMPY_AVAILABLE = False
    logger.warning("NumPy not available. Some operations will use fallbacks.")


@dataclass
class ModelConfig:
    """Configuration for the simulated ML model"""
    name: str
    version: str
    complexity: int
    thread_safe: bool = True


class ThreadedShowcaseAdapter(ThreadSafeAdapter):
    """
    Showcase adapter demonstrating thread-safe concurrent execution patterns.

    This adapter is explicitly designed for multi-threaded environments and
    demonstrates all three thread safety patterns.
    """

    __thread_safe__ = True  # Declare thread safety for validation

    def __init__(self):
        super().__init__()

        # PATTERN 1: Shared Read-Only Resources
        # These are loaded once and never modified, safe for concurrent reads
        self.model_config = ModelConfig(
            name="ThreadedShowcaseModel",
            version="2.0",
            complexity=5
        )

        # Simulate pre-loaded model weights (read-only)
        self.model_weights = self._initialize_model_weights()

        # Shared immutable configuration
        self.processing_config = {
            "timeout": 30,
            "batch_size": 10,
            "cache_enabled": True
        }

        # PATTERN 3: Shared Mutable State (requires locking)
        # These will be modified and need protection
        self.global_stats = {
            "total_requests": 0,
            "total_compute_time": 0.0,
            "max_concurrent": 0,
            "thread_usage": {}
        }

        self.request_history = []  # Protected by self._lock

        logger.info(f"✅ {self.__class__.__name__} initialized (thread-safe mode)")

    def _initialize_model_weights(self) -> Optional[Any]:
        """Initialize model weights (simulated)"""
        if NUMPY_AVAILABLE:
            # Simulate large model weights
            return {
                'layer1': np.random.randn(100, 100),
                'layer2': np.random.randn(100, 50),
                'layer3': np.random.randn(50, 10)
            }
        else:
            return {
                'layer1': [[random.random() for _ in range(100)] for _ in range(100)],
                'layer2': [[random.random() for _ in range(50)] for _ in range(100)],
                'layer3': [[random.random() for _ in range(10)] for _ in range(50)]
            }

    # Tool Methods - All demonstrate thread-safe patterns

    @thread_safe_method
    @tool(description="Simple ping operation for connectivity testing")
    def ping(self, message: str = "pong") -> dict:
        """
        Simple ping operation for testing connectivity and session affinity.

        Demonstrates:
        - Basic request/response pattern
        - Thread identification
        - Minimal latency operation
        """
        thread_name = threading.current_thread().name
        return {
            "message": message,
            "timestamp": time.time(),
            "thread": thread_name
        }

    @thread_safe_method
    @tool(description="CPU-intensive computation demonstrating concurrent execution")
    def compute_intensive(self, data: List[float], iterations: int = 1000) -> dict:
        """
        Perform CPU-intensive computation.

        Demonstrates:
        - CPU-bound work that benefits from parallelism
        - Thread-safe shared state updates
        - Per-thread caching

        This operation is designed to stress-test concurrent execution and
        show performance benefits of multi-threading.
        """
        thread_name = threading.current_thread().name
        start_time = time.time()

        # PATTERN 2: Thread-local cache
        cache = self.get_thread_local('compute_cache', {})
        cache_key = hashlib.md5(str(data).encode()).hexdigest()

        if cache_key in cache:
            logger.debug(f"[{thread_name}] Cache hit for {cache_key[:8]}")
            return cache[cache_key]

        # CPU-intensive computation
        result = self._perform_computation(data, iterations)

        # Update thread-local cache
        cache[cache_key] = result
        self.set_thread_local('compute_cache', cache)

        # PATTERN 3: Update shared stats with lock
        execution_time = time.time() - start_time
        self._update_global_stats(thread_name, execution_time)

        result['execution_time_ms'] = int(execution_time * 1000)
        result['thread'] = thread_name
        result['cached'] = False

        return result

    def _perform_computation(self, data: List[float], iterations: int) -> dict:
        """Perform actual CPU-intensive computation"""
        if NUMPY_AVAILABLE:
            # Use NumPy for realistic computation (releases GIL!)
            arr = np.array(data)
            for _ in range(iterations):
                arr = np.sin(arr) * np.cos(arr) + arr * 0.1
            result_value = float(np.mean(arr))
        else:
            # Fallback computation
            import math
            result = data.copy()
            for _ in range(iterations):
                result = [math.sin(x) * math.cos(x) + x * 0.1 for x in result]
            result_value = sum(result) / len(result)

        return {
            "result": result_value,
            "iterations": iterations,
            "input_size": len(data)
        }

    @thread_safe_method
    @tool(description="Matrix multiplication using shared model weights")
    def matrix_multiply(self, input_vector: List[float]) -> dict:
        """
        Perform matrix multiplication using pre-loaded weights.

        Demonstrates:
        - Safe concurrent access to shared read-only resources
        - CPU-intensive linear algebra operations
        - GIL-releasing NumPy operations
        """
        thread_name = threading.current_thread().name
        start_time = time.time()

        # PATTERN 1: Access shared read-only model weights
        # This is safe because weights are never modified after initialization
        if NUMPY_AVAILABLE:
            input_arr = np.array(input_vector)

            # Simulate forward pass through model layers
            # NumPy operations release the GIL, allowing true parallelism
            activation = np.dot(input_arr, self.model_weights['layer1'])
            activation = np.maximum(0, activation)  # ReLU
            activation = np.dot(activation, self.model_weights['layer2'])
            activation = np.maximum(0, activation)
            output = np.dot(activation, self.model_weights['layer3'])

            result = output.tolist()
        else:
            # Fallback: simple computation
            result = [sum(x * random.random() for x in input_vector) for _ in range(10)]

        execution_time = time.time() - start_time

        # PATTERN 3: Update shared stats
        self._update_global_stats(thread_name, execution_time)

        return {
            "output": result,
            "input_size": len(input_vector),
            "output_size": len(result),
            "execution_time_ms": int(execution_time * 1000),
            "thread": thread_name,
            "model": self.model_config.name
        }

    @thread_safe_method
    @tool(description="Simulate batch processing with concurrent workers")
    def batch_process(self, items: List[Dict[str, Any]], delay_ms: int = 10) -> dict:
        """
        Process multiple items concurrently.

        Demonstrates:
        - Batch processing patterns
        - Thread-local state management
        - Progress tracking
        """
        thread_name = threading.current_thread().name
        start_time = time.time()

        # PATTERN 2: Thread-local batch state
        batch_id = f"batch_{int(time.time() * 1000)}_{thread_name}"
        self.set_thread_local('current_batch_id', batch_id)

        results = []
        for i, item in enumerate(items):
            # Simulate processing delay
            time.sleep(delay_ms / 1000.0)

            processed = {
                "item_id": i,
                "input": item,
                "output": hashlib.md5(str(item).encode()).hexdigest()[:16],
                "thread": thread_name
            }
            results.append(processed)

        execution_time = time.time() - start_time

        # PATTERN 3: Update global stats
        with self.acquire_lock():
            self.global_stats["total_requests"] += 1
            self.request_history.append({
                "batch_id": batch_id,
                "items_processed": len(items),
                "execution_time": execution_time,
                "thread": thread_name,
                "timestamp": time.time()
            })

        return {
            "batch_id": batch_id,
            "items_processed": len(items),
            "results": results,
            "execution_time_ms": int(execution_time * 1000),
            "thread": thread_name
        }

    @thread_safe_method
    @tool(description="Get adapter statistics and thread usage")
    def get_adapter_stats(self) -> dict:
        """
        Get comprehensive adapter statistics.

        Demonstrates:
        - Safe read of shared mutable state
        - Combining base class stats with adapter-specific metrics
        """
        # Get base class stats (already thread-safe)
        base_stats = self.get_stats()

        # PATTERN 3: Read shared mutable state with lock
        with self.acquire_lock():
            global_stats_copy = self.global_stats.copy()
            history_count = len(self.request_history)

        return {
            **base_stats,
            "global_stats": global_stats_copy,
            "history_entries": history_count,
            "model": {
                "name": self.model_config.name,
                "version": self.model_config.version,
                "complexity": self.model_config.complexity
            },
            "numpy_available": NUMPY_AVAILABLE
        }

    @thread_safe_method
    @tool(description="Stress test for concurrent request handling")
    def stress_test(self, duration_ms: int = 100, complexity: int = 1000) -> dict:
        """
        Stress test for concurrent execution.

        Performs CPU-intensive work for the specified duration to test
        thread pool behavior and concurrent execution performance.
        """
        thread_name = threading.current_thread().name
        start_time = time.time()
        target_duration = duration_ms / 1000.0

        iterations = 0
        while (time.time() - start_time) < target_duration:
            # CPU-intensive operation
            if NUMPY_AVAILABLE:
                data = np.random.randn(complexity)
                _ = np.fft.fft(data)
            else:
                data = [random.random() for _ in range(complexity)]
                _ = sum(x ** 2 for x in data)
            iterations += 1

        execution_time = time.time() - start_time

        # Update stats
        self._update_global_stats(thread_name, execution_time)

        return {
            "iterations": iterations,
            "target_duration_ms": duration_ms,
            "actual_duration_ms": int(execution_time * 1000),
            "complexity": complexity,
            "thread": thread_name,
            "ops_per_second": iterations / execution_time
        }

    @thread_safe_method
    @tool(description="Clear thread-local caches")
    def clear_caches(self) -> dict:
        """
        Clear thread-local caches for the current thread.

        Demonstrates:
        - Thread-local storage management
        - Safe cache invalidation
        """
        thread_name = threading.current_thread().name

        # Clear all thread-local storage for this thread
        self.clear_thread_local()

        return {
            "status": "success",
            "message": f"Caches cleared for thread {thread_name}",
            "thread": thread_name
        }

    @thread_safe_method
    @tool(description="Get recent request history")
    def get_history(self, limit: int = 10) -> dict:
        """
        Get recent request history.

        Demonstrates:
        - Safe read of shared mutable collections
        - Pagination patterns
        """
        with self.acquire_lock():
            # Get last N entries safely
            recent = self.request_history[-limit:] if self.request_history else []
            # Make a deep copy to avoid external modifications
            history_copy = [entry.copy() for entry in recent]

        return {
            "entries": history_copy,
            "total_entries": len(self.request_history),
            "returned": len(history_copy)
        }

    # Helper methods

    def _update_global_stats(self, thread_name: str, execution_time: float):
        """Update global statistics with thread-safe locking"""
        with self.acquire_lock():
            self.global_stats["total_requests"] += 1
            self.global_stats["total_compute_time"] += execution_time

            # Track thread usage
            if thread_name not in self.global_stats["thread_usage"]:
                self.global_stats["thread_usage"][thread_name] = 0
            self.global_stats["thread_usage"][thread_name] += 1

            # Track max concurrent (from tracker)
            active = self._tracker.get_stats()["total_active_requests"]
            if active > self.global_stats["max_concurrent"]:
                self.global_stats["max_concurrent"] = active

    # Optional: Custom session context methods

    def set_session_context(self, context):
        """Set session context (called by framework)"""
        self._session_context = context

    def initialize(self):
        """Initialize adapter (called by framework)"""
        logger.info(f"Initializing {self.__class__.__name__} in thread {threading.current_thread().name}")

    @thread_safe_method
    def execute_tool(self, tool_name: str, arguments: dict, context) -> Any:
        """
        Execute a tool by name with given arguments.

        This method provides the interface expected by the gRPC bridge server.
        It dispatches to the appropriate tool method using the base adapter's
        call_tool infrastructure.

        Args:
            tool_name: Name of the tool to execute
            arguments: Dictionary of tool arguments
            context: Session context

        Returns:
            Tool execution result
        """
        # Set session context if provided
        if context and not self._session_context:
            self._session_context = context

        # Use the base adapter's call_tool which handles @tool decorated methods
        return self.call_tool(tool_name, **arguments)
