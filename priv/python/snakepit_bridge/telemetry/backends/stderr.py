"""Stderr telemetry backend.

This backend writes telemetry events to stderr as JSON, which can be captured
by Elixir. This is a fallback mechanism for adapters that don't support gRPC.
"""

from __future__ import annotations

import json
import sys
import time
from typing import Any, Dict, Optional

from .base import TelemetryBackend


class StderrBackend(TelemetryBackend):
    """Telemetry backend that writes events to stderr as JSON.

    Events are prefixed with "TELEMETRY:" for easy parsing by Elixir.

    Example output:
        TELEMETRY:{"event":"tool.execution.start","measurements":{"system_time":1698234567890},"metadata":{"tool":"predict"},"timestamp_ns":1698234567890123456,"correlation_id":"abc-123"}
    """

    def emit(
        self,
        event_name: str,
        measurements: Dict[str, Any],
        metadata: Optional[Dict[str, Any]] = None,
        correlation_id: Optional[str] = None,
    ) -> None:
        """Emit a telemetry event to stderr.

        Args:
            event_name: Event name in dotted notation
            measurements: Numeric measurements
            metadata: Contextual metadata
            correlation_id: Optional correlation ID
        """
        payload = {
            "event": event_name,
            "measurements": measurements,
            "metadata": metadata or {},
            "timestamp_ns": time.time_ns(),
            "correlation_id": correlation_id or "",
        }

        try:
            sys.stderr.write(f"TELEMETRY:{json.dumps(payload)}\n")
            sys.stderr.flush()
        except Exception as e:
            # Don't crash the worker if telemetry fails
            sys.stderr.write(f"TELEMETRY_ERROR: {e}\n")
            sys.stderr.flush()
