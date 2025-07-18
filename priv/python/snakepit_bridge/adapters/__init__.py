"""
Snakepit Bridge Adapters

This package contains various adapter implementations for different use cases.
Adapters extend the BaseCommandHandler to provide specific functionality.
"""

from .generic import GenericCommandHandler

__all__ = ["GenericCommandHandler"]