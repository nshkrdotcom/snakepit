"""Basic operations handler for showcase adapter."""

import time
from typing import Dict, Any
from datetime import datetime
from ..tool import Tool
from snakepit_bridge import telemetry


class BasicOpsHandler:
    """Handler for basic operations like ping, echo, and error demonstrations."""
    
    def get_tools(self) -> Dict[str, Tool]:
        """Return all tools provided by this handler."""
        return {
            "ping": Tool(self.ping),
            "echo": Tool(self.echo),
            "add": Tool(self.add),
            "error_demo": Tool(self.error_demo),
            "adapter_info": Tool(self.adapter_info),
            "telemetry_demo": Tool(self.telemetry_demo),
        }
    
    def ping(self, ctx, message: str = "pong") -> Dict[str, str]:
        """Simple ping operation."""
        return {"message": message, "timestamp": str(time.time())}
    
    def echo(self, ctx, **kwargs) -> Dict[str, Any]:
        """Echo back all provided arguments."""
        return {"echoed": kwargs}
    
    def add(self, ctx, a: float, b: float) -> float:
        """Add two numbers together."""
        return a + b
    
    def error_demo(self, ctx, error_type: str = "generic") -> None:
        """Demonstrate error handling with different error types."""
        if error_type == "value":
            raise ValueError("This is a demonstration ValueError")
        elif error_type == "runtime":
            raise RuntimeError("This is a demonstration RuntimeError")
        else:
            raise Exception("This is a generic exception")
    
    def adapter_info(self, ctx) -> Dict[str, Any]:
        """Return information about the adapter capabilities."""
        return {
            "adapter_name": "ShowcaseAdapter",
            "version": "2.0.0",  # Updated version for refactored adapter
            "capabilities": [
                "binary_serialization",
                "streaming",
                "ml_workflows",
                "session_state_via_elixir"
            ],
            "handlers": [
                "BasicOpsHandler",
                "SessionOpsHandler",
                "BinaryOpsHandler",
                "StreamingOpsHandler",
                "ConcurrentOpsHandler",
                "MLWorkflowHandler"
            ]
        }

    def telemetry_demo(self, ctx, operation: str = "compute", delay_ms: int = 100) -> Dict[str, Any]:
        """
        Demonstrate telemetry emission from Python.

        This tool shows how to use the telemetry API to emit events that are
        captured by Elixir and made available to :telemetry handlers.

        Args:
            ctx: Session context
            operation: Name of the operation to simulate
            delay_ms: How long to simulate work (milliseconds)

        Returns:
            Dict with operation results and telemetry info
        """
        correlation_id = telemetry.get_correlation_id()

        # Example 1: Manual event emission
        telemetry.emit(
            "tool.execution.start",
            {"system_time": time.time_ns()},
            {"tool": "telemetry_demo", "operation": operation},
            correlation_id=correlation_id
        )

        # Example 2: Using span context manager (automatic timing)
        with telemetry.span("tool.execution", {"tool": "telemetry_demo", "operation": operation}, correlation_id):
            # Simulate some work
            time.sleep(delay_ms / 1000.0)

            # Emit a custom metric during the span
            telemetry.emit(
                "tool.result_size",
                {"bytes": 42},
                {"tool": "telemetry_demo"},
                correlation_id=correlation_id
            )

        return {
            "operation": operation,
            "delay_ms": delay_ms,
            "telemetry_enabled": telemetry.is_enabled(),
            "correlation_id": correlation_id,
            "message": "Telemetry events emitted successfully! Check Elixir :telemetry handlers."
        }