"""Telemetry module for Snakepit Bridge.

This module provides a high-level API for emitting telemetry events from Python
workers. Events are captured by Elixir and re-emitted as :telemetry events.

The module supports pluggable backends:
- gRPC backend (default): Streams events over gRPC
- stderr backend (fallback): Writes JSON to stderr

Example usage:
    from snakepit_bridge import telemetry

    # Emit a simple event
    telemetry.emit(
        "tool.execution.start",
        {"system_time": time.time_ns()},
        {"tool": "predict"},
        correlation_id="abc-123"
    )

    # Use span context manager
    with telemetry.span("tool.execution", {"tool": "predict"}, "abc-123"):
        result = do_work()
        telemetry.emit("tool.result_size", {"bytes": len(result)})
"""

from __future__ import annotations

import time
from contextlib import contextmanager
from typing import Any, Dict, Optional

from .manager import get_backend, set_backend, is_enabled

# Import OpenTelemetry tracing functions from the old module
from ..otel_tracing import (
    setup_tracing,
    get_tracer,
    correlation_filter,
    new_correlation_id,
    set_correlation_id,
    reset_correlation_id,
    get_correlation_id,
    outgoing_metadata,
    CORRELATION_HEADER,
    span as otel_span  # Rename to avoid conflict with new span()
)

# Re-export key functions
__all__ = [
    # Event streaming (new)
    "emit",
    "span",  # New event streaming span
    "set_backend",
    "get_backend",
    "is_enabled",
    # OpenTelemetry (old, for backward compatibility)
    "setup_tracing",
    "get_tracer",
    "correlation_filter",
    "new_correlation_id",
    "set_correlation_id",
    "reset_correlation_id",
    "get_correlation_id",
    "outgoing_metadata",
    "CORRELATION_HEADER",
    "otel_span"  # Old OpenTelemetry span (renamed)
]


def emit(
    event: str,
    measurements: Dict[str, Any],
    metadata: Optional[Dict[str, Any]] = None,
    correlation_id: Optional[str] = None,
) -> None:
    """Emit a telemetry event.

    Events are sent to the active backend (gRPC stream, stderr, etc.).

    Args:
        event: Event name in dotted notation (e.g., "tool.execution.start")
        measurements: Numeric measurements (duration, size, count, etc.)
        metadata: Contextual metadata (tool name, operation, etc.)
        correlation_id: Optional correlation ID for distributed tracing

    Example:
        telemetry.emit(
            "tool.execution.stop",
            {"duration": 1234, "bytes": 5000},
            {"tool": "predict", "model": "gpt-4"},
            correlation_id="abc-123"
        )
    """
    backend = get_backend()
    if backend:
        backend.emit(event, measurements, metadata, correlation_id)


@contextmanager
def span(
    operation: str,
    metadata: Optional[Dict[str, Any]] = None,
    correlation_id: Optional[str] = None,
):
    """Context manager for timing operations and emitting start/stop/exception events.

    Automatically emits:
    - {operation}.start at entry
    - {operation}.stop at exit (with duration)
    - {operation}.exception on error (with duration and error info)

    Args:
        operation: Operation name (e.g., "tool.execution")
        metadata: Metadata to include in all events
        correlation_id: Optional correlation ID for distributed tracing

    Example:
        with telemetry.span("inference", {"model": "gpt-4"}, correlation_id):
            result = model.predict(input_data)

    Yields:
        None
    """
    start_time = time.time_ns()

    # Emit start event
    emit(
        f"{operation}.start",
        {"system_time": start_time},
        metadata,
        correlation_id
    )

    try:
        yield
        # Emit stop event with duration
        end_time = time.time_ns()
        duration = end_time - start_time

        emit(
            f"{operation}.stop",
            {"duration": duration},
            metadata,
            correlation_id
        )
    except Exception as e:
        # Emit exception event
        end_time = time.time_ns()
        duration = end_time - start_time

        error_metadata = dict(metadata or {})
        error_metadata["error_type"] = type(e).__name__
        error_metadata["error_message"] = str(e)

        emit(
            f"{operation}.exception",
            {"duration": duration},
            error_metadata,
            correlation_id
        )
        raise
