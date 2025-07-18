#!/usr/bin/env python3
"""
Generic Python Bridge for Snakepit

A minimal, framework-agnostic bridge that demonstrates the protocol
without dependencies on any specific ML framework like DSPy.

This can serve as a template for creating your own adapters.

To create a custom adapter:
1. Create a new class that inherits from BaseCommandHandler
2. Override _register_commands() to register your command handlers
3. Implement your command handler methods
4. Pass an instance of your handler to ProtocolHandler

Example:
    class MyCustomHandler(BaseCommandHandler):
        def _register_commands(self):
            self.register_command("my_command", self.handle_my_command)
        
        def handle_my_command(self, args):
            return {"result": "processed", "input": args}
    
    handler = ProtocolHandler(MyCustomHandler())
    handler.run()
"""

import sys
import json
import struct
import time
import signal
import select
import os
from datetime import datetime
from typing import Dict, Any, Optional, Callable
from abc import ABC, abstractmethod


class BaseCommandHandler(ABC):
    """
    Abstract base class for command handlers.
    
    This provides a clean interface for creating custom adapters that can
    be plugged into the ProtocolHandler without modifying the core bridge logic.
    """
    
    def __init__(self):
        self.start_time = time.time()
        self.request_count = 0
        self._command_registry = {}
        self._register_commands()
    
    @abstractmethod
    def _register_commands(self):
        """
        Register all supported commands. Subclasses should override this
        to register their command handlers.
        
        Example:
            self.register_command("ping", self.handle_ping)
            self.register_command("compute", self.handle_compute)
        """
        pass
    
    def register_command(self, command: str, handler: Callable[[Dict[str, Any]], Dict[str, Any]]):
        """Register a command handler."""
        self._command_registry[command] = handler
    
    def get_supported_commands(self) -> list:
        """Get list of supported commands."""
        return list(self._command_registry.keys())
    
    def process_command(self, command: str, args: Dict[str, Any]) -> Dict[str, Any]:
        """Process a command and return the result."""
        self.request_count += 1
        
        handler = self._command_registry.get(command)
        if handler:
            return handler(args)
        else:
            return self._handle_unknown_command(command)
    
    def _handle_unknown_command(self, command: str) -> Dict[str, Any]:
        """Handle unknown commands. Can be overridden by subclasses."""
        return {
            "status": "error",
            "error": f"Unknown command: {command}",
            "supported_commands": self.get_supported_commands(),
            "timestamp": time.time()
        }


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
                "version": "1.0.0",
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


def safe_print(message: str, file=sys.stderr):
    """Safely print a message, ignoring broken pipe errors."""
    try:
        print(message, file=file)
        file.flush()
    except (BrokenPipeError, IOError):
        # Silently ignore broken pipe errors
        pass


class ProtocolHandler:
    """
    Handles the wire protocol for communication with Snakepit.
    
    Protocol:
    - 4-byte big-endian length header
    - JSON payload
    """
    
    def __init__(self, command_handler: Optional[BaseCommandHandler] = None):
        """
        Initialize the protocol handler.
        
        Args:
            command_handler: An instance of BaseCommandHandler or its subclasses.
                           If None, uses GenericCommandHandler as default.
        """
        self.command_handler = command_handler or GenericCommandHandler()
        self.shutdown_requested = False
        # Disable Python's broken pipe error handling
        signal.signal(signal.SIGPIPE, signal.SIG_DFL) if hasattr(signal, 'SIGPIPE') else None
    
    def read_message(self) -> Optional[Dict[str, Any]]:
        """Read a message from stdin using 4-byte length protocol."""
        try:
            
            # Read 4-byte length header
            length_data = sys.stdin.buffer.read(4)
            if len(length_data) != 4:
                # EOF or pipe closed, return empty dict to signal shutdown
                return {}
            
            # Unpack length (big-endian)
            length = struct.unpack('>I', length_data)[0]
            
            # Read JSON payload
            json_data = sys.stdin.buffer.read(length)
            if len(json_data) != length:
                return {}
            
            # Parse JSON
            return json.loads(json_data.decode('utf-8'))
        except (BrokenPipeError, IOError, OSError):
            # Pipe closed, return empty dict to signal shutdown
            return {}
        except Exception as e:
            safe_print(f"Error reading message: {e}")
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
        except (BrokenPipeError, IOError, OSError):
            # Pipe closed, exit silently
            return False
        except Exception as e:
            safe_print(f"Error writing message: {e}")
            return False
    
    def request_shutdown(self):
        """Request graceful shutdown of the main loop."""
        self.shutdown_requested = True
    
    def run(self):
        """Main message loop with non-blocking reads."""
        # Only print startup message if stderr is still connected
        if not os.isatty(sys.stderr.fileno()):
            try:
                # Check if we can write to stderr
                sys.stderr.write("")
                sys.stderr.flush()
                safe_print("Generic Bridge started in pool-worker mode")
            except:
                # stderr is closed, skip the message
                pass
        else:
            safe_print("Generic Bridge started in pool-worker mode")
        
        while not self.shutdown_requested:
            # Read request
            request = self.read_message()
            
            if request is None:
                # Error reading message, continue
                continue
            
            if not request:
                # Empty dict signals EOF or pipe closed, exit cleanly
                break
            
            # Extract request details
            request_id = request.get("id")
            command = request.get("command")
            args = request.get("args", {})
            
            try:
                # Process command
                result = self.command_handler.process_command(command, args)
                
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
        
        # Exit cleanly
        sys.exit(0)


def main():
    """Main entry point."""
    
    # Suppress broken pipe errors globally
    try:
        # Redirect stderr to devnull on shutdown to avoid broken pipe errors
        import atexit
        def suppress_broken_pipe():
            try:
                sys.stderr.close()
            except:
                pass
            try:
                sys.stdout.close()
            except:
                pass
        atexit.register(suppress_broken_pipe)
    except:
        pass
    
    # Create protocol handler
    handler = ProtocolHandler()
    
    # Set up graceful shutdown handler for SIGTERM
    def graceful_shutdown_handler(signum, frame):
        """Handle SIGTERM by requesting shutdown and exiting cleanly."""
        # Request shutdown of the main loop
        handler.request_shutdown()
        # Close streams to prevent broken pipe errors
        try:
            sys.stdout.close()
        except:
            pass
        try:
            sys.stderr.close()
        except:
            pass
        # Exit cleanly
        os._exit(0)
    
    # Register the signal handler for SIGTERM and SIGINT
    signal.signal(signal.SIGTERM, graceful_shutdown_handler)
    signal.signal(signal.SIGINT, graceful_shutdown_handler)
    
    if len(sys.argv) > 1 and sys.argv[1] == "--help":
        print("Generic Snakepit Bridge")
        print("Usage: python generic_bridge.py [--mode pool-worker]")
        print("")
        print("This bridge provides an extensible architecture for creating custom adapters.")
        print("See the module docstring for examples on how to create your own adapter.")
        print("")
        print("Default supported commands:")
        handler = GenericCommandHandler()
        for cmd in handler.get_supported_commands():
            print(f"  {cmd}")
        return
    
    # Start protocol handler
    try:
        handler.run()
    except (KeyboardInterrupt, BrokenPipeError, IOError):
        # Clean shutdown, suppress errors
        os._exit(0)
    except Exception as e:
        safe_print(f"Bridge error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
