"""
Heartbeat utilities for Snakepit Python bridge workers.

This module introduces a configurable heartbeat client that can be enabled once
the bridge needs to actively report liveness back to the BEAM runtime.  The
implementation is intentionally conservative: heartbeats are disabled by
default, but the client can be toggled on via worker configuration or command
line flags.
"""

from __future__ import annotations

import asyncio
import inspect
import logging
import os
import random
import re
import signal
import time
from dataclasses import asdict, dataclass, fields
from typing import Any, Awaitable, Callable, Mapping, Optional

import grpc
from google.protobuf.timestamp_pb2 import Timestamp

import snakepit_bridge_pb2 as pb2
from snakepit_bridge import telemetry


@dataclass(frozen=True)
class HeartbeatConfig:
    """
    Normalised heartbeat configuration for Python workers.

    Attributes mirror the Elixir-side defaults so that toggling the feature can
    be coordinated from application configuration without duplicating logic.
    """

    enabled: bool = True
    interval_ms: int = 2_000
    timeout_ms: int = 10_000
    max_missed_heartbeats: int = 3
    initial_delay_ms: int = 0
    jitter_ms: int = 0
    dependent: bool = True

    @classmethod
    def from_mapping(
        cls,
        options: Optional[Mapping[str, Any]],
        *,
        defaults: Optional["HeartbeatConfig"] = None,
    ) -> "HeartbeatConfig":
        """
        Build a configuration instance from an arbitrary mapping.

        Unknown keys are ignored; recognised keys are coerced to the correct type.
        """

        base = defaults or cls()
        data = asdict(base)

        if not options:
            return cls(**data)

        field_names = {field.name for field in fields(cls)}

        for raw_key, value in options.items():
            normalized_key = cls._normalize_field(raw_key)
            if normalized_key not in field_names:
                continue

            data[normalized_key] = cls._coerce_value(normalized_key, value, data[normalized_key])

        return cls(**data)

    @staticmethod
    def _normalize_field(key: Any) -> str:
        if isinstance(key, str):
            snake = re.sub(r"([A-Z])", lambda match: "_" + match.group(1).lower(), key).lower()
            return snake
        return str(key)

    @staticmethod
    def _coerce_value(field_name: str, value: Any, default: Any) -> Any:
        if field_name in {"enabled", "dependent"}:
            if isinstance(value, bool):
                return value
            if isinstance(value, str):
                return value.strip().lower() in {"1", "true", "t", "yes", "y", "on"}
            return bool(value)

        if field_name in {"interval_ms", "timeout_ms", "initial_delay_ms", "jitter_ms"}:
            try:
                return int(value)
            except (TypeError, ValueError):
                return default

        if field_name == "max_missed_heartbeats":
            try:
                coerced = int(value)
                return coerced if coerced >= 0 else default
            except (TypeError, ValueError):
                return default

        return value


class HeartbeatClient:
    """
    Async heartbeat loop that periodically invokes the Elixir bridge.

    The client is safe to construct even when heartbeats are disabled; `start()`
    becomes a no-op in that case.  This allows us to wire the client now and
    simply flip a configuration flag once the full heartbeat path is ready.
    """

    def __init__(
        self,
        stub: Any,
        session_id: str,
        config: Optional[HeartbeatConfig] = None,
        *,
        loop: Optional[asyncio.AbstractEventLoop] = None,
        on_threshold_exceeded: Optional[Callable[[int], Awaitable[None]]] = None,
    ) -> None:
        self._stub = stub
        self._session_id = session_id
        self._config = config or HeartbeatConfig()
        self._loop = loop

        if self._config.dependent:
            self._on_threshold_exceeded = (
                on_threshold_exceeded or self._default_shutdown_handler
            )
        else:
            self._on_threshold_exceeded = on_threshold_exceeded

        self._task: Optional[asyncio.Task[None]] = None
        self._running = False
        self._missed = 0
        self._last_ping_monotonic: Optional[float] = None
        self._last_success_monotonic: Optional[float] = None

        self._logger = logging.getLogger(f"{__name__}.HeartbeatClient")

    @property
    def config(self) -> HeartbeatConfig:
        return self._config

    def start(self) -> bool:
        """
        Begin the heartbeat loop. Returns True if the loop was scheduled.
        """
        if not self._config.enabled:
            self._logger.debug("Heartbeat disabled; start() is a no-op.")
            return False

        if self._running:
            return False

        loop = self._loop or self._get_loop()
        if loop is None:
            self._logger.warning("No running event loop; cannot start heartbeat client.")
            return False

        self._running = True
        self._task = loop.create_task(self._run(), name="snakepit-heartbeat")
        return True

    async def stop(self) -> None:
        """
        Stop the heartbeat loop and cancel any outstanding RPC.
        """
        self._running = False
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
            finally:
                self._task = None

    def status(self) -> Mapping[str, Any]:
        """
        Current heartbeat status snapshot useful for diagnostics.
        """
        return {
            "enabled": self._config.enabled,
            "missed_heartbeats": self._missed,
            "last_ping_monotonic": self._last_ping_monotonic,
            "last_success_monotonic": self._last_success_monotonic,
            "running": self._running,
            "dependent": self._config.dependent,
        }

    async def ping_once(self) -> Optional[pb2.HeartbeatResponse]:
        """
        Send a single heartbeat request immediately.
        """
        if not self._config.enabled:
            return None

        return await self._send_ping()

    async def _run(self) -> None:
        try:
            if self._config.initial_delay_ms > 0:
                await asyncio.sleep(self._config.initial_delay_ms / 1000.0)

            while self._running:
                await self._send_ping()

                interval = self._config.interval_ms / 1000.0
                if self._config.jitter_ms > 0:
                    interval += random.uniform(0.0, self._config.jitter_ms / 1000.0)

                await asyncio.sleep(interval)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            self._logger.exception("Heartbeat loop crashed: %s", exc)
        finally:
            self._running = False

    async def _send_ping(self) -> Optional[pb2.HeartbeatResponse]:
        self._last_ping_monotonic = time.monotonic()

        request = pb2.HeartbeatRequest(session_id=self._session_id)
        request.client_time.CopyFrom(self._timestamp_now())

        timeout_seconds = max(self._config.timeout_ms, 0) / 1000.0

        try:
            attributes = {"snakepit.session_id": self._session_id}

            with telemetry.span(
                "HeartbeatClient/SendPing", attributes=attributes
            ):
                metadata = telemetry.outgoing_metadata()
                call = self._stub.Heartbeat(
                    request, timeout=timeout_seconds, metadata=metadata
                )
            if inspect.isawaitable(call):
                response = await call
            else:
                loop = self._get_loop()
                if loop is None:
                    response = call  # Fall back to synchronous call
                else:
                    response = await loop.run_in_executor(None, lambda: call)

            self._missed = 0
            self._last_success_monotonic = time.monotonic()
            return response
        except grpc.RpcError as rpc_error:
            self._logger.warning(
                "Heartbeat RPC failed for session %s: %s",
                self._session_id,
                rpc_error,
            )
        except Exception as exc:
            self._logger.warning(
                "Heartbeat request failed for session %s: %s",
                self._session_id,
                exc,
            )

        self._missed += 1

        if self._missed >= self._config.max_missed_heartbeats:
            if self._on_threshold_exceeded:
                await self._emit_threshold_notification()
            elif not self._config.dependent:
                self._logger.info(
                    "Heartbeat threshold reached for session %s (missed=%s); worker is independent.",
                    self._session_id,
                    self._missed,
                )

        return None

    async def _emit_threshold_notification(self) -> None:
        if not self._on_threshold_exceeded:
            return

        try:
            await self._on_threshold_exceeded(self._missed)
        except Exception:
            self._logger.exception("Heartbeat threshold handler raised an exception.")

    async def _default_shutdown_handler(self, missed: int) -> None:
        self._logger.error(
            "Heartbeat threshold exceeded for session %s (missed=%s); terminating.",
            self._session_id,
            missed,
        )

        loop = self._get_loop()

        try:
            if loop:
                loop.call_soon(os.kill, os.getpid(), signal.SIGTERM)
                loop.call_later(5.0, os._exit, 70)
            else:
                os.kill(os.getpid(), signal.SIGTERM)
        except Exception:
            self._logger.exception("Failed to signal process termination; forcing exit.")
            os._exit(70)

    @staticmethod
    def _timestamp_now() -> Timestamp:
        timestamp = Timestamp()
        timestamp.GetCurrentTime()
        return timestamp

    @staticmethod
    def _get_loop() -> Optional[asyncio.AbstractEventLoop]:
        try:
            return asyncio.get_running_loop()
        except RuntimeError:
            try:
                return asyncio.get_event_loop()
            except RuntimeError:
                return None
