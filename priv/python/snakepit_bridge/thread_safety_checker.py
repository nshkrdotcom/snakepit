"""
Thread Safety Checker - Runtime validation for concurrent adapter execution.

This module provides utilities to detect thread safety violations during
development and testing of multi-threaded adapters.

Features:
- Concurrent access detection
- Known unsafe library detection
- Race condition warnings
- Thread contention monitoring
- Performance profiling per thread

Usage:
    from snakepit_bridge.thread_safety_checker import ThreadSafetyChecker, check_thread_safe

    # Decorator usage
    @check_thread_safe
    def my_function(adapter):
        adapter.execute_tool("compute", {})

    # Context manager usage
    with ThreadSafetyChecker(enabled=True) as checker:
        # Run concurrent operations
        results = run_concurrent_tests()
        print(checker.get_report())
"""

import threading
import warnings
import time
import sys
import inspect
import functools
from typing import Set, Dict, List, Optional, Callable, Any
from collections import defaultdict
from contextlib import contextmanager
import logging

logger = logging.getLogger(__name__)


class ThreadSafetyChecker:
    """
    Runtime checker for thread safety violations.

    Monitors:
    - Concurrent method access without proper locking
    - Use of known thread-unsafe libraries
    - Thread contention patterns
    - Performance per thread
    """

    # Known thread-unsafe libraries
    UNSAFE_LIBRARIES = {
        'matplotlib': {
            'reason': 'Not thread-safe. Use thread-local figures or explicit locking.',
            'safe_pattern': 'Use threading.local() for figure storage',
            'docs': 'https://matplotlib.org/stable/users/explain/interactive.html'
        },
        'sqlite3': {
            'reason': 'Not thread-safe by default (check_same_thread=True)',
            'safe_pattern': 'Use check_same_thread=False with caution, or connection per thread',
            'docs': 'https://docs.python.org/3/library/sqlite3.html#sqlite3.connect'
        },
        'pandas': {
            'reason': 'DataFrame operations are not thread-safe (as of v2.0)',
            'safe_pattern': 'Use explicit locking or process-based parallelism',
            'docs': 'https://pandas.pydata.org/docs/'
        }
    }

    def __init__(self, enabled: bool = True, strict_mode: bool = False):
        """
        Initialize thread safety checker.

        Args:
            enabled: Enable checking (set False for production)
            strict_mode: Raise exceptions instead of warnings
        """
        self.enabled = enabled
        self.strict_mode = strict_mode

        # Access tracking: method_name -> set of thread IDs
        self.access_map: Dict[str, Set[int]] = defaultdict(set)
        self.access_times: Dict[str, List[float]] = defaultdict(list)

        # Warnings issued to avoid spam
        self.warnings_issued: Set[str] = set()

        # Thread performance tracking
        self.thread_stats: Dict[int, Dict[str, Any]] = defaultdict(lambda: {
            "calls": 0,
            "total_time": 0.0,
            "methods": set()
        })

        # Lock for internal state
        self._lock = threading.Lock()

        # Start time
        self.start_time = time.time()

    def check_method_access(self, method_name: str, caller_frame: Optional[Any] = None):
        """
        Check if a method is being accessed concurrently.

        Args:
            method_name: Name of the method being accessed
            caller_frame: Frame info for detailed diagnostics
        """
        if not self.enabled:
            return

        thread_id = threading.get_ident()
        thread_name = threading.current_thread().name
        access_time = time.time()

        with self._lock:
            # Track access
            self.access_map[method_name].add(thread_id)
            self.access_times[method_name].append(access_time)

            # Update thread stats
            self.thread_stats[thread_id]["calls"] += 1
            self.thread_stats[thread_id]["methods"].add(method_name)

            # Check for concurrent access
            num_threads = len(self.access_map[method_name])
            if num_threads > 1:
                warning_key = f"{method_name}_concurrent"
                if warning_key not in self.warnings_issued:
                    self.warnings_issued.add(warning_key)

                    msg = (
                        f"⚠️  THREAD SAFETY: Method '{method_name}' accessed by "
                        f"{num_threads} different threads concurrently. "
                        f"Current thread: {thread_name} (ID: {thread_id})"
                    )

                    if caller_frame:
                        msg += f"\n  Called from: {caller_frame.filename}:{caller_frame.lineno}"

                    if self.strict_mode:
                        raise RuntimeError(msg)
                    else:
                        warnings.warn(msg, RuntimeWarning, stacklevel=3)
                        logger.warning(msg)

    def check_library_safety(self, imported_modules: Optional[Set[str]] = None):
        """
        Check if any imported libraries are known to be thread-unsafe.

        Args:
            imported_modules: Set of module names, or None to check sys.modules
        """
        if not self.enabled:
            return

        if imported_modules is None:
            imported_modules = set(sys.modules.keys())

        warnings_found = []

        for lib_name, info in self.UNSAFE_LIBRARIES.items():
            if lib_name in imported_modules:
                warning_key = f"unsafe_lib_{lib_name}"
                if warning_key not in self.warnings_issued:
                    self.warnings_issued.add(warning_key)

                    msg = (
                        f"⚠️  THREAD SAFETY: Unsafe library '{lib_name}' detected\n"
                        f"  Reason: {info['reason']}\n"
                        f"  Safe Pattern: {info['safe_pattern']}\n"
                        f"  Docs: {info['docs']}"
                    )

                    warnings_found.append(msg)

                    if self.strict_mode:
                        raise RuntimeError(msg)
                    else:
                        warnings.warn(msg, RuntimeWarning, stacklevel=2)
                        logger.warning(msg)

        return warnings_found

    @contextmanager
    def track_execution(self, method_name: str):
        """
        Context manager to track method execution time per thread.

        Usage:
            with checker.track_execution("my_method"):
                do_work()
        """
        if not self.enabled:
            yield
            return

        thread_id = threading.get_ident()
        start_time = time.time()

        try:
            yield
        finally:
            execution_time = time.time() - start_time
            with self._lock:
                self.thread_stats[thread_id]["total_time"] += execution_time

    def get_report(self) -> dict:
        """
        Get comprehensive thread safety report.

        Returns:
            Dict with statistics, warnings, and recommendations
        """
        with self._lock:
            total_time = time.time() - self.start_time

            # Calculate concurrent access patterns
            concurrent_methods = {
                method: len(threads)
                for method, threads in self.access_map.items()
                if len(threads) > 1
            }

            # Thread utilization
            thread_utilization = {}
            for thread_id, stats in self.thread_stats.items():
                thread_utilization[thread_id] = {
                    "calls": stats["calls"],
                    "total_time": stats["total_time"],
                    "methods": list(stats["methods"]),
                    "avg_time_per_call": (
                        stats["total_time"] / stats["calls"]
                        if stats["calls"] > 0 else 0
                    )
                }

            return {
                "enabled": self.enabled,
                "strict_mode": self.strict_mode,
                "total_runtime": total_time,
                "warnings_issued": len(self.warnings_issued),
                "warnings": list(self.warnings_issued),
                "concurrent_accesses": concurrent_methods,
                "total_methods_tracked": len(self.access_map),
                "total_threads_seen": len(self.thread_stats),
                "thread_utilization": thread_utilization,
                "recommendations": self._generate_recommendations(concurrent_methods)
            }

    def _generate_recommendations(self, concurrent_methods: Dict[str, int]) -> List[str]:
        """Generate recommendations based on detected issues"""
        recommendations = []

        if concurrent_methods:
            recommendations.append(
                f"⚠️  {len(concurrent_methods)} methods accessed concurrently. "
                "Ensure proper locking or use thread-local storage."
            )

        if len(self.thread_stats) == 1:
            recommendations.append(
                "ℹ️  Only one thread detected. Consider testing with --max-workers > 1."
            )

        if len(self.warnings_issued) == 0:
            recommendations.append("✅ No thread safety issues detected.")

        return recommendations

    def reset(self):
        """Reset all tracking data"""
        with self._lock:
            self.access_map.clear()
            self.access_times.clear()
            self.warnings_issued.clear()
            self.thread_stats.clear()
            self.start_time = time.time()

    def __enter__(self):
        """Context manager entry"""
        self.reset()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit"""
        if self.enabled:
            report = self.get_report()
            logger.info("Thread Safety Check Report:")
            logger.info(f"  Total methods tracked: {report['total_methods_tracked']}")
            logger.info(f"  Concurrent accesses: {len(report['concurrent_accesses'])}")
            logger.info(f"  Warnings issued: {report['warnings_issued']}")
            for rec in report['recommendations']:
                logger.info(f"  {rec}")
        return False


# Global checker instance
_global_checker = ThreadSafetyChecker(enabled=False)


def enable_checking(strict_mode: bool = False):
    """Enable global thread safety checking"""
    global _global_checker
    _global_checker = ThreadSafetyChecker(enabled=True, strict_mode=strict_mode)
    logger.info("Thread safety checking enabled" + (" (strict mode)" if strict_mode else ""))


def disable_checking():
    """Disable global thread safety checking"""
    global _global_checker
    _global_checker.enabled = False
    logger.info("Thread safety checking disabled")


def get_global_checker() -> ThreadSafetyChecker:
    """Get the global checker instance"""
    return _global_checker


# Decorators

def check_thread_safe(func: Callable) -> Callable:
    """
    Decorator to check thread safety of a function.

    Automatically tracks method access and reports concurrent access patterns.

    Usage:
        @check_thread_safe
        def my_concurrent_function(arg):
            # Function that may be called from multiple threads
            return process(arg)
    """
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        method_name = func.__name__

        # Get caller frame for diagnostics
        frame = inspect.currentframe()
        caller_frame = frame.f_back if frame else None

        # Check access
        _global_checker.check_method_access(method_name, caller_frame)

        # Track execution
        with _global_checker.track_execution(method_name):
            return func(*args, **kwargs)

    return wrapper


def require_thread_safe_adapter(func: Callable) -> Callable:
    """
    Decorator to enforce that an adapter is thread-safe.

    Raises ValueError if adapter doesn't declare thread safety.

    Usage:
        @require_thread_safe_adapter
        def concurrent_operation(adapter):
            # This will only run if adapter is thread-safe
            adapter.process()
    """
    @functools.wraps(func)
    def wrapper(adapter, *args, **kwargs):
        if not hasattr(adapter, '__thread_safe__'):
            raise ValueError(
                f"Adapter {adapter.__class__.__name__} does not declare thread safety. "
                f"Set __thread_safe__ = True if the adapter is thread-safe."
            )

        if not adapter.__thread_safe__:
            raise ValueError(
                f"Adapter {adapter.__class__.__name__} is explicitly marked as NOT thread-safe. "
                f"Use process mode instead of threaded mode."
            )

        return func(adapter, *args, **kwargs)

    return wrapper


# Utility functions

def validate_adapter_thread_safety(adapter_class: type) -> bool:
    """
    Validate that an adapter class declares thread safety.

    Args:
        adapter_class: Adapter class to validate

    Returns:
        True if thread-safe, False otherwise

    Raises:
        ValueError: If adapter is not thread-safe (when strict checking enabled)
    """
    is_safe = (
        hasattr(adapter_class, '__thread_safe__') and
        adapter_class.__thread_safe__ is True
    )

    if not is_safe and _global_checker.strict_mode:
        raise ValueError(
            f"Adapter {adapter_class.__name__} is not thread-safe. "
            f"Required: __thread_safe__ = True"
        )

    return is_safe


def check_common_pitfalls(adapter_instance) -> List[str]:
    """
    Check for common thread safety pitfalls in an adapter.

    Returns:
        List of warning messages
    """
    warnings_list = []

    # Check 1: Has shared mutable state without locking?
    if hasattr(adapter_instance, '__dict__'):
        mutable_attrs = []
        for attr_name, attr_value in adapter_instance.__dict__.items():
            if not attr_name.startswith('_'):
                if isinstance(attr_value, (list, dict, set)):
                    mutable_attrs.append(attr_name)

        if mutable_attrs and not hasattr(adapter_instance, '_lock'):
            warnings_list.append(
                f"⚠️  Adapter has mutable shared state {mutable_attrs} but no lock. "
                f"Consider adding self._lock = threading.Lock()"
            )

    # Check 2: Check for unsafe libraries
    _global_checker.check_library_safety()

    # Check 3: Missing __thread_safe__ declaration
    if not hasattr(adapter_instance.__class__, '__thread_safe__'):
        warnings_list.append(
            "⚠️  Adapter does not declare __thread_safe__. "
            "Add __thread_safe__ = True/False to your adapter class."
        )

    return warnings_list


def print_thread_safety_report():
    """Print a formatted thread safety report"""
    report = _global_checker.get_report()

    print("\n" + "="*70)
    print("Thread Safety Analysis Report")
    print("="*70)

    print(f"\nExecution Summary:")
    print(f"  Total Runtime: {report['total_runtime']:.2f}s")
    print(f"  Threads Detected: {report['total_threads_seen']}")
    print(f"  Methods Tracked: {report['total_methods_tracked']}")
    print(f"  Warnings Issued: {report['warnings_issued']}")

    if report['concurrent_accesses']:
        print(f"\nConcurrent Accesses Detected:")
        for method, count in report['concurrent_accesses'].items():
            print(f"  - {method}: {count} threads")

    if report['recommendations']:
        print(f"\nRecommendations:")
        for rec in report['recommendations']:
            print(f"  {rec}")

    print("\n" + "="*70 + "\n")
