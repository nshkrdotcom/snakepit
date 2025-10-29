import io
import logging
import os

import asyncio

import pytest

import grpc_server

from snakepit_bridge import telemetry


def test_span_uses_incoming_correlation_metadata():
    metadata = ("x-snakepit-correlation-id", "cid-123")

    with telemetry.otel_span("test-span", context_metadata=[metadata]):
        assert telemetry.get_correlation_id() == "cid-123"

    assert telemetry.get_correlation_id() is None


def test_outgoing_metadata_includes_active_correlation():
    token = telemetry.set_correlation_id("cid-456")

    try:
        metadata = telemetry.outgoing_metadata()
        assert (telemetry.CORRELATION_HEADER, "cid-456") in metadata
    finally:
        telemetry.reset_correlation_id(token)


def test_logging_filter_injects_correlation(monkeypatch):
    token = telemetry.set_correlation_id("cid-log")

    try:
        record = logging.LogRecord(
            name="snakepit",
            level=logging.INFO,
            pathname=__file__,
            lineno=10,
            msg="hello",
            args=(),
            exc_info=None,
        )

        log_filter = telemetry.correlation_filter()
        assert log_filter.filter(record)
        assert getattr(record, "correlation_id") == "cid-log"
    finally:
        telemetry.reset_correlation_id(token)


def test_log_record_factory_adds_correlation_id(monkeypatch):
    monkeypatch.setenv("SNAKEPIT_OTEL_CONSOLE", "0")
    telemetry.setup_tracing()

    stream = io.StringIO()
    handler = logging.StreamHandler(stream)
    formatter = logging.Formatter("%(correlation_id)s")
    handler.setFormatter(formatter)

    logger = logging.getLogger("telemetry-test")
    previous_handlers = logger.handlers[:]
    previous_propagate = logger.propagate
    logger.handlers = [handler]
    logger.setLevel(logging.INFO)
    logger.propagate = False

    try:
        logger.info("no correlation context")
        output = stream.getvalue().strip().splitlines()
        assert output[-1] == "-"

        token = telemetry.set_correlation_id("cid-factory")
        try:
            logger.info("context set")
        finally:
            telemetry.reset_correlation_id(token)

        output = stream.getvalue().strip().splitlines()
        assert output[-1] == "cid-factory"
    finally:
        logger.handlers = previous_handlers
        logger.propagate = previous_propagate


def test_proxy_outgoing_metadata_carries_correlation():
    os.environ["SNAKEPIT_OTEL_CONSOLE"] = "0"
    telemetry.setup_tracing()
    token = telemetry.set_correlation_id("cid-proxy")

    class _FakeStub:
        def __init__(self):
            self.metadata = None

        async def InitializeSession(self, request, metadata=None):
            self.metadata = metadata
            return "ok"

    try:
        service = object.__new__(grpc_server.BridgeServiceServicer)
        service.elixir_stub = _FakeStub()

        asyncio.run(
            grpc_server.BridgeServiceServicer._proxy_to_elixir(
                service,
                "InitializeSession",
                request={"session_id": "s-123"},
            )
        )

        assert service.elixir_stub.metadata is not None
        assert (
            telemetry.CORRELATION_HEADER,
            "cid-proxy",
        ) in service.elixir_stub.metadata
    finally:
        telemetry.reset_correlation_id(token)
