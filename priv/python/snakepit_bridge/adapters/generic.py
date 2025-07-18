#!/usr/bin/env python3
"""
Generic Snakepit Bridge Adapter

A framework-agnostic adapter that provides basic commands without external dependencies.
This serves as both a working implementation and an example for custom adapters.
"""

import sys
import time
from typing import Dict, Any

from ..core import BaseCommandHandler


class GenericCommandHandler(BaseCommandHandler):
    """
    Generic command handler that provides basic commands without external dependencies.
    This serves as both a working implementation and an example for custom adapters.
    """
    
    def _register_commands(self):
        """Register all generic commands."""
        self.register_command("ping", self.handle_ping)
        self.register_command("echo", self.handle_echo)
        self.register_command("compute", self.handle_compute)
        self.register_command("info", self.handle_info)
        
    def handle_ping(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Handle ping command - basic health check."""
        return {
            "status": "ok",
            "bridge_type": "generic",
            "uptime": time.time() - self.start_time,
            "requests_handled": self.request_count,
            "timestamp": time.time(),
            "python_version": sys.version,
            "worker_id": args.get("worker_id", "unknown"),
            "echo": args  # Echo back the arguments for testing
        }
    
    def handle_echo(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Handle echo command - useful for testing."""
        return {
            "status": "ok",
            "echoed": args,
            "timestamp": time.time()
        }
    
    def handle_compute(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Handle compute command - simple math operations."""
        try:
            operation = args.get("operation", "add")
            a = args.get("a", 0)
            b = args.get("b", 0)
            
            if operation == "add":
                result = a + b
            elif operation == "subtract":
                result = a - b
            elif operation == "multiply":
                result = a * b
            elif operation == "divide":
                if b == 0:
                    raise ValueError("Division by zero")
                result = a / b
            else:
                raise ValueError(f"Unsupported operation: {operation}")
            
            return {
                "status": "ok",
                "operation": operation,
                "inputs": {"a": a, "b": b},
                "result": result,
                "timestamp": time.time()
            }
        except Exception as e:
            return {
                "status": "error", 
                "error": str(e),
                "timestamp": time.time()
            }
    
    def handle_info(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Handle info command - return bridge information."""
        return {
            "status": "ok",
            "bridge_info": {
                "name": "Generic Snakepit Bridge",
                "version": "2.0.0",
                "supported_commands": self.get_supported_commands(),
                "uptime": time.time() - self.start_time,
                "total_requests": self.request_count
            },
            "system_info": {
                "python_version": sys.version,
                "platform": sys.platform
            },
            "timestamp": time.time()
        }