#!/usr/bin/env python3
"""
Generic Python Bridge for Snakepit

A minimal, framework-agnostic bridge that demonstrates the protocol
without dependencies on any specific ML framework like DSPy.

This can serve as a template for creating your own adapters.
"""

import sys
import json
import struct
import time
from datetime import datetime
from typing import Dict, Any, Optional


class GenericBridge:
    """
    Generic bridge that handles basic commands without external dependencies.
    """
    
    def __init__(self):
        self.start_time = time.time()
        self.request_count = 0
        
    def handle_ping(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Handle ping command - basic health check."""
        self.request_count += 1
        
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
                "version": "1.0.0",
                "supported_commands": ["ping", "echo", "compute", "info"],
                "uptime": time.time() - self.start_time,
                "total_requests": self.request_count
            },
            "system_info": {
                "python_version": sys.version,
                "platform": sys.platform
            },
            "timestamp": time.time()
        }
    
    def process_command(self, command: str, args: Dict[str, Any]) -> Dict[str, Any]:
        """Process a command and return the result."""
        handlers = {
            "ping": self.handle_ping,
            "echo": self.handle_echo, 
            "compute": self.handle_compute,
            "info": self.handle_info
        }
        
        handler = handlers.get(command)
        if handler:
            return handler(args)
        else:
            return {
                "status": "error",
                "error": f"Unknown command: {command}",
                "supported_commands": list(handlers.keys()),
                "timestamp": time.time()
            }


class ProtocolHandler:
    """
    Handles the wire protocol for communication with Snakepit.
    
    Protocol:
    - 4-byte big-endian length header
    - JSON payload
    """
    
    def __init__(self):
        self.bridge = GenericBridge()
    
    def read_message(self) -> Optional[Dict[str, Any]]:
        """Read a message from stdin using the 4-byte length protocol."""
        try:
            # Read 4-byte length header
            length_data = sys.stdin.buffer.read(4)
            if len(length_data) != 4:
                return None
            
            # Unpack length (big-endian)
            length = struct.unpack('>I', length_data)[0]
            
            # Read JSON payload
            json_data = sys.stdin.buffer.read(length)
            if len(json_data) != length:
                return None
            
            # Parse JSON
            return json.loads(json_data.decode('utf-8'))
        except Exception as e:
            print(f"Error reading message: {e}", file=sys.stderr)
            return None
    
    def write_message(self, message: Dict[str, Any]) -> bool:
        """Write a message to stdout using the 4-byte length protocol."""
        try:
            # Encode JSON
            json_data = json.dumps(message, separators=(',', ':')).encode('utf-8')
            
            # Write length header (big-endian)
            length = struct.pack('>I', len(json_data))
            sys.stdout.buffer.write(length)
            
            # Write JSON payload
            sys.stdout.buffer.write(json_data)
            sys.stdout.buffer.flush()
            
            return True
        except Exception as e:
            print(f"Error writing message: {e}", file=sys.stderr)
            return False
    
    def run(self):
        """Main message loop."""
        print("Generic Bridge started in pool-worker mode", file=sys.stderr)
        
        while True:
            # Read request
            request = self.read_message()
            if request is None:
                break
            
            # Extract request details
            request_id = request.get("id")
            command = request.get("command")
            args = request.get("args", {})
            
            try:
                # Process command
                result = self.bridge.process_command(command, args)
                
                # Send success response
                response = {
                    "id": request_id,
                    "success": True,
                    "result": result,
                    "timestamp": datetime.now().isoformat()
                }
            except Exception as e:
                # Send error response
                response = {
                    "id": request_id,
                    "success": False,
                    "error": str(e),
                    "timestamp": datetime.now().isoformat()
                }
            
            # Write response
            if not self.write_message(response):
                break


def main():
    """Main entry point."""
    if len(sys.argv) > 1 and sys.argv[1] == "--help":
        print("Generic Snakepit Bridge")
        print("Usage: python generic_bridge.py [--mode pool-worker]")
        print("")
        print("Supported commands:")
        print("  ping    - Health check")
        print("  echo    - Echo arguments back") 
        print("  compute - Simple math operations")
        print("  info    - Bridge information")
        return
    
    # Start protocol handler
    handler = ProtocolHandler()
    try:
        handler.run()
    except KeyboardInterrupt:
        print("Bridge shutting down", file=sys.stderr)
    except Exception as e:
        print(f"Bridge error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()