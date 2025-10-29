"""Base telemetry backend interface."""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Any, Dict, Optional


class TelemetryBackend(ABC):
    """Abstract base class for telemetry backends.

    Backends are responsible for transporting telemetry events from Python
    workers to the Elixir telemetry system.
    """

    @abstractmethod
    def emit(
        self,
        event_name: str,
        measurements: Dict[str, Any],
        metadata: Optional[Dict[str, Any]] = None,
        correlation_id: Optional[str] = None,
    ) -> None:
        """Emit a telemetry event.

        Args:
            event_name: Event name in dotted notation (e.g., "tool.execution.start")
            measurements: Numeric measurements (duration, size, count, etc.)
            metadata: Contextual metadata (tool name, operation, etc.)
            correlation_id: Optional correlation ID for distributed tracing
        """
        pass

    def close(self) -> None:
        """Close the backend and release resources.

        This is called when the worker is shutting down.
        """
        pass
