"""
Snakepit Bridge Package

A robust, production-ready Python bridge for the Snakepit pool communication system.
Provides framework-agnostic bridge infrastructure and extensible adapter system.
"""

__version__ = "2.0.0"
__author__ = "Snakepit Team"

# Import core components for easy access
from .session_context import SessionContext
from .heartbeat import HeartbeatClient, HeartbeatConfig

__all__ = [
    "SessionContext",
    "HeartbeatClient",
    "HeartbeatConfig",
    "__version__"
]
