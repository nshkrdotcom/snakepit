from __future__ import annotations

import logging
import os
import uuid
from contextlib import contextmanager
from contextvars import ContextVar
from typing import Iterable, List, Optional, Sequence, Tuple

try:  # Optional OpenTelemetry dependency
    from opentelemetry import trace
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor, ConsoleSpanExporter
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
except ImportError:  # pragma: no cover - degraded mode when OTEL unavailable
    trace = None
    TracerProvider = None
    BatchSpanProcessor = None
    ConsoleSpanExporter = None
    OTLPSpanExporter = None


CORRELATION_HEADER = "x-snakepit-correlation-id"

_correlation_id: ContextVar[Optional[str]] = ContextVar("snakepit_correlation_id", default=None)
_tracer = None
_tracing_ready = False
_log_factory_installed = False
_original_log_factory = logging.getLogRecordFactory()


def setup_tracing() -> None:
    """Initialise OpenTelemetry tracing if the SDK is available."""

    global _tracing_ready, _tracer

    if _tracing_ready:
        return

    if trace is None or TracerProvider is None or BatchSpanProcessor is None:
        _tracing_ready = True
        _install_log_record_factory()
        return

    service_name = os.environ.get("SNAKEPIT_SERVICE_NAME", "snakepit.python.bridge")

    resource = Resource.create({
        "service.name": service_name,
        "service.namespace": "snakepit",
        "service.instance.id": os.environ.get("SNAKEPIT_INSTANCE_ID", uuid.uuid4().hex),
    })

    provider = TracerProvider(resource=resource)
    exporter = _select_exporter()
    if exporter is not None:
        provider.add_span_processor(BatchSpanProcessor(exporter))

    trace.set_tracer_provider(provider)
    _tracer = trace.get_tracer("snakepit.bridge")
    _tracing_ready = True
    _install_log_record_factory()


def get_tracer():
    return _tracer if _tracing_ready else None


def new_correlation_id() -> str:
    return uuid.uuid4().hex


def set_correlation_id(value: str):
    return _correlation_id.set(value)


def reset_correlation_id(token) -> None:
    if token is not None:
        _correlation_id.reset(token)


def get_correlation_id(default: Optional[str] = None) -> Optional[str]:
    value = _correlation_id.get()
    return value if value is not None else default


@contextmanager
def span(
    name: str,
    *,
    context_metadata: Optional[Sequence[Tuple[str, str]]] = None,
    attributes: Optional[dict] = None,
):
    """Create an OpenTelemetry span bound to the current correlation ID."""

    correlation = _extract_correlation_id(context_metadata) or get_correlation_id() or new_correlation_id()
    token = set_correlation_id(correlation)

    tracer = get_tracer()

    if tracer is None:
        try:
            yield None
        finally:
            reset_correlation_id(token)
        return

    with tracer.start_as_current_span(name) as span_object:
        if attributes:
            for key, value in attributes.items():
                span_object.set_attribute(key, value)

        span_object.set_attribute("snakepit.correlation_id", correlation)

        try:
            yield span_object
        finally:
            reset_correlation_id(token)


def outgoing_metadata(initial: Optional[Iterable[Tuple[str, str]]] = None) -> List[Tuple[str, str]]:
    """Return metadata enriched with the active correlation identifier."""

    metadata: List[Tuple[str, str]] = list(initial) if initial else []
    correlation = get_correlation_id()

    if correlation:
        metadata.append((CORRELATION_HEADER, correlation))

    return metadata


class _CorrelationIdFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:  # pragma: no cover - trivial
        record.correlation_id = get_correlation_id("-")
        return True


def correlation_filter() -> logging.Filter:
    return _CorrelationIdFilter()


def _extract_correlation_id(metadata: Optional[Sequence[Tuple[str, str]]]) -> Optional[str]:
    if not metadata:
        return None

    for key, value in metadata:
        if key.lower() == CORRELATION_HEADER:
            return value

    return None


def _select_exporter():  # pragma: no cover - thin wrapper
    endpoint = os.environ.get("SNAKEPIT_OTEL_ENDPOINT")

    if endpoint and OTLPSpanExporter is not None:
        return OTLPSpanExporter(endpoint=endpoint)

    if ConsoleSpanExporter is not None and os.environ.get("SNAKEPIT_OTEL_CONSOLE", "true").lower() in {"1", "true", "yes"}:
        return ConsoleSpanExporter()

    return None


def _install_log_record_factory() -> None:
    """Ensure every log record carries a correlation_id attribute."""
    global _log_factory_installed

    if _log_factory_installed:
        return

    original_factory = _original_log_factory

    def record_factory(*args, **kwargs):
        record = original_factory(*args, **kwargs)
        if not hasattr(record, "correlation_id"):
            record.correlation_id = get_correlation_id("-")
        else:
            record.correlation_id = record.correlation_id or get_correlation_id("-")
        return record

    logging.setLogRecordFactory(record_factory)
    _log_factory_installed = True
