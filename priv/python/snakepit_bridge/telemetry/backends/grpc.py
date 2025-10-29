"""gRPC telemetry backend.

This backend sends telemetry events via the gRPC telemetry stream to Elixir.
"""

from __future__ import annotations

from typing import Any, Dict, Optional, TYPE_CHECKING

from .base import TelemetryBackend

if TYPE_CHECKING:
    from ..stream import TelemetryStream


class GrpcBackend(TelemetryBackend):
    """Telemetry backend that uses gRPC telemetry stream.

    This backend delegates to a TelemetryStream instance, which manages
    the actual gRPC stream communication with Elixir.

    Args:
        stream: TelemetryStream instance to use for emission
    """

    def __init__(self, stream: TelemetryStream) -> None:
        """Initialize the gRPC backend.

        Args:
            stream: TelemetryStream instance to use
        """
        self._stream = stream

    def emit(
        self,
        event_name: str,
        measurements: Dict[str, Any],
        metadata: Optional[Dict[str, Any]] = None,
        correlation_id: Optional[str] = None,
    ) -> None:
        """Emit a telemetry event via gRPC stream.

        Args:
            event_name: Event name in dotted notation
            measurements: Numeric measurements
            metadata: Contextual metadata
            correlation_id: Optional correlation ID
        """
        self._stream.emit(event_name, measurements, metadata, correlation_id)

    def close(self) -> None:
        """Close the gRPC stream gracefully."""
        self._stream.close()

    @property
    def stream(self) -> TelemetryStream:
        """Get the underlying TelemetryStream instance.

        Returns:
            The TelemetryStream instance
        """
        return self._stream
