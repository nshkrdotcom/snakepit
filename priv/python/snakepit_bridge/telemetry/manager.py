"""Telemetry backend manager.

This module manages the active telemetry backend, allowing runtime switching
between gRPC, stderr, and other backends.
"""

from __future__ import annotations

from typing import Optional

from .backends.base import TelemetryBackend

_backend: Optional[TelemetryBackend] = None


def set_backend(backend: Optional[TelemetryBackend]) -> None:
    """Set the active telemetry backend.

    Args:
        backend: Backend instance or None to disable telemetry
    """
    global _backend
    _backend = backend


def get_backend() -> Optional[TelemetryBackend]:
    """Get the current active telemetry backend.

    Returns:
        The active backend or None if telemetry is disabled
    """
    return _backend


def is_enabled() -> bool:
    """Check if telemetry is currently enabled.

    Returns:
        True if a backend is set, False otherwise
    """
    return _backend is not None
