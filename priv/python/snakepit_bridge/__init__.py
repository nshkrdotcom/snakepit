"""
Snakepit Bridge Package

A robust, production-ready Python bridge for the Snakepit pool communication system.
Provides framework-agnostic bridge infrastructure and extensible adapter system.
"""

__version__ = "2.0.0"
__author__ = "Snakepit Team"

# Import core components for easy access
from .core import BaseCommandHandler, ProtocolHandler
from .adapters.generic import GenericCommandHandler

__all__ = [
    "BaseCommandHandler",
    "ProtocolHandler", 
    "GenericCommandHandler",
    "__version__"
]