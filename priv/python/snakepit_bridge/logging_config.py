"""
Centralized logging configuration for Snakepit Python components.

Environment variables:
    SNAKEPIT_LOG_LEVEL: debug, info, warning, error, none (default: error)
"""

from __future__ import annotations

import logging
import os
import sys
from typing import Dict

_LEVELS: Dict[str, int] = {
    "debug": logging.DEBUG,
    "info": logging.INFO,
    "warning": logging.WARNING,
    "error": logging.ERROR,
    "none": logging.CRITICAL + 1,
}

_DEFAULT_CORRELATION_ID = "-"


class _CorrelationIdFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        if not hasattr(record, "correlation_id") or not record.correlation_id:
            record.correlation_id = _DEFAULT_CORRELATION_ID
        return True


def _ensure_correlation_filter() -> None:
    root_logger = logging.getLogger()
    if not any(isinstance(f, _CorrelationIdFilter) for f in root_logger.filters):
        root_logger.addFilter(_CorrelationIdFilter())


def configure_logging(force: bool = False) -> None:
    """Configure logging based on environment variables."""
    level_str = os.environ.get("SNAKEPIT_LOG_LEVEL", "error").lower()
    level = _LEVELS.get(level_str, logging.ERROR)

    if level_str == "none":
        logging.disable(logging.CRITICAL)
    else:
        logging.disable(logging.NOTSET)

    logging.basicConfig(
        level=level,
        format=(
            "%(asctime)s - [%(threadName)s] - %(name)s - %(levelname)s "
            "- [corr=%(correlation_id)s] %(message)s"
        ),
        stream=sys.stderr,
        force=force,
    )

    _ensure_correlation_filter()

    # Suppress noisy third-party loggers
    logging.getLogger("grpc").setLevel(logging.WARNING)
    logging.getLogger("urllib3").setLevel(logging.WARNING)


def get_logger(name: str) -> logging.Logger:
    """Get a logger with the standard Snakepit namespace."""
    if name.startswith("snakepit."):
        return logging.getLogger(name)

    if name.startswith("snakepit_bridge."):
        suffix = name[len("snakepit_bridge.") :]
        return logging.getLogger(f"snakepit.bridge.{suffix}")

    return logging.getLogger(f"snakepit.{name}")
