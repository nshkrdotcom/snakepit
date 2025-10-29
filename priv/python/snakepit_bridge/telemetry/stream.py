"""Telemetry stream for gRPC backend.

This module implements the TelemetryStream class that manages the bidirectional
gRPC telemetry stream between Python workers and Elixir.
"""

from __future__ import annotations

import asyncio
import random
import time
from typing import Any, AsyncIterable, Dict, Optional

import snakepit_bridge_pb2 as pb


class TelemetryStream:
    """Collects events and flushes them onto the gRPC response stream.

    This class manages a queue of telemetry events and streams them to Elixir
    via gRPC. It also handles control messages from Elixir to adjust sampling
    rates, enable/disable telemetry, and filter events.

    Attributes:
        enabled: Whether telemetry is currently enabled
        sampling_rate: Fraction of events to emit (0.0 to 1.0)
    """

    def __init__(self, max_buffer: int = 1024) -> None:
        """Initialize the telemetry stream.

        Args:
            max_buffer: Maximum number of events to buffer before dropping
        """
        self.enabled = True
        self.sampling_rate = 1.0
        self._queue: asyncio.Queue[Optional[pb.TelemetryEvent]] = asyncio.Queue(
            maxsize=max_buffer
        )
        self._dropped_count = 0

    async def stream(
        self,
        control_iter: AsyncIterable[pb.TelemetryControl],
        context: Any,
    ):
        """BridgeService.StreamTelemetry implementation.

        This is the gRPC stream handler that:
        1. Consumes control messages from Elixir (sampling, filters, etc.)
        2. Yields telemetry events back to Elixir

        Args:
            control_iter: Stream of control messages from Elixir
            context: gRPC context

        Yields:
            TelemetryEvent: Events to send to Elixir
        """

        async def consume_control() -> None:
            """Background task to consume control messages from Elixir."""
            try:
                async for control in control_iter:
                    self._handle_control(control)
            except Exception:
                # Control stream closed or error
                pass

        # Start control message consumer in background
        control_task = asyncio.create_task(consume_control())

        try:
            # Yield events from queue until sentinel (None) is received
            while True:
                event = await self._queue.get()
                if event is None:
                    # Sentinel value indicates stream should close
                    break
                yield event
        finally:
            # Clean up control consumer task
            control_task.cancel()
            try:
                await control_task
            except asyncio.CancelledError:
                pass

    def emit(
        self,
        event_name: str,
        measurements: Dict[str, float | int | str],
        metadata: Optional[Dict[str, Any]] = None,
        correlation_id: Optional[str] = None,
    ) -> None:
        """Emit a telemetry event to the stream.

        This method is called by the high-level telemetry API to emit events.
        Events are queued and sent to Elixir asynchronously.

        Args:
            event_name: Event name in dotted notation (e.g., "tool.execution.start")
            measurements: Numeric measurements
            metadata: Contextual metadata
            correlation_id: Optional correlation ID for distributed tracing
        """
        if not self.enabled:
            return

        # Apply sampling
        if self.sampling_rate < 1.0 and random.random() > self.sampling_rate:
            return

        # Build protobuf event
        event = pb.TelemetryEvent(
            event_parts=event_name.split("."),
            timestamp_ns=time.time_ns(),
            correlation_id=correlation_id or "",
        )

        # Add measurements
        for key, value in measurements.items():
            if isinstance(value, bool):
                value = int(value)

            field = event.measurements[key]
            if isinstance(value, int):
                field.int_value = value
            elif isinstance(value, float):
                field.float_value = value
            else:
                field.string_value = str(value)

        # Add metadata
        for key, value in (metadata or {}).items():
            event.metadata[key] = str(value)

        # Try to add to queue without blocking
        try:
            self._queue.put_nowait(event)
        except asyncio.QueueFull:
            # Drop event instead of blocking critical worker code
            self._dropped_count += 1

    def _handle_control(self, control: pb.TelemetryControl) -> None:
        """Handle a control message from Elixir.

        Control messages allow Elixir to adjust telemetry behavior at runtime
        without restarting the worker.

        Args:
            control: Control message from Elixir
        """
        which = control.WhichOneof("control")

        if which == "toggle":
            self.enabled = control.toggle.enabled

        elif which == "sampling":
            # Clamp sampling rate to [0.0, 1.0]
            self.sampling_rate = max(0.0, min(control.sampling.sampling_rate, 1.0))

        elif which == "filter":
            # TODO: Implement filtering in Phase 2.2
            # For now, filters are acknowledged but not applied
            pass

    def close(self) -> None:
        """Close the telemetry stream gracefully.

        This pushes a sentinel value (None) to the queue, which signals the
        stream consumer to terminate.
        """
        try:
            self._queue.put_nowait(None)  # type: ignore[arg-type]
        except asyncio.QueueFull:
            pass

    @property
    def dropped_count(self) -> int:
        """Get the number of events dropped due to queue saturation.

        Returns:
            Number of dropped events
        """
        return self._dropped_count
