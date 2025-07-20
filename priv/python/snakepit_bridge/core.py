#!/usr/bin/env python3
"""
Snakepit Bridge Core Components

Contains the fundamental classes and protocol handling logic for Snakepit bridges.
This module provides the abstract base classes and communication protocol
implementation that all adapters build upon.

Supports both JSON and MessagePack wire protocols for high-performance communication.
"""

import sys
import json
import struct
import time
import signal
import select
import os
from datetime import datetime
from typing import Dict, Any, Optional, Callable, Literal
from abc import ABC, abstractmethod

# Try to import msgpack, fall back to JSON if not available
try:
    import msgpack
    MSGPACK_AVAILABLE = True
except ImportError:
    MSGPACK_AVAILABLE = False


def safe_print(message: str, file=sys.stderr):
    """Safely print a message, ignoring broken pipe errors."""
    try:
        print(message, file=file)
        file.flush()
    except (BrokenPipeError, IOError):
        # Silently ignore broken pipe errors
        pass


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


class ProtocolHandler:
    """
    Handles the wire protocol for communication with Snakepit.
    
    Protocol:
    - 4-byte big-endian length header
    - Payload (JSON or MessagePack)
    
    Supports protocol negotiation for selecting the optimal serialization format.
    """
    
    def __init__(self, command_handler: Optional[BaseCommandHandler] = None, 
                 protocol: Literal["json", "msgpack", "auto"] = "auto",
                 quiet: bool = False):
        """
        Initialize the protocol handler.
        
        Args:
            command_handler: An instance of BaseCommandHandler or its subclasses.
                           If None, raises ValueError as no default is provided
                           in the core module.
            protocol: Wire protocol to use - "json", "msgpack", or "auto" (default).
                     "auto" will negotiate with the Elixir side.
            quiet: If True, suppress startup messages.
        """
        if command_handler is None:
            raise ValueError("command_handler is required in ProtocolHandler")
        
        self.command_handler = command_handler
        self.shutdown_requested = False
        self.protocol = protocol
        self._negotiated_protocol = None
        self.quiet = quiet
        
        # Disable Python's broken pipe error handling
        signal.signal(signal.SIGPIPE, signal.SIG_DFL) if hasattr(signal, 'SIGPIPE') else None
    
    def _get_active_protocol(self) -> str:
        """Get the active protocol (after negotiation if applicable)."""
        if self._negotiated_protocol:
            return self._negotiated_protocol
        elif self.protocol == "auto":
            # If auto but not negotiated yet, default to msgpack if available
            return "msgpack" if MSGPACK_AVAILABLE else "json"
        else:
            return self.protocol
    
    def _convert_msgpack_strings(self, obj):
        """Convert byte strings to strings recursively while preserving binary data."""
        if isinstance(obj, bytes):
            # Try to decode as UTF-8, if it fails, keep as bytes (binary data)
            try:
                return obj.decode('utf-8')
            except UnicodeDecodeError:
                return obj
        elif isinstance(obj, dict):
            return {
                self._convert_msgpack_strings(k): self._convert_msgpack_strings(v)
                for k, v in obj.items()
            }
        elif isinstance(obj, list):
            return [self._convert_msgpack_strings(item) for item in obj]
        else:
            return obj
    
    def _negotiate_protocol(self) -> bool:
        """
        Negotiate the wire protocol with the Elixir side.
        
        Returns True if negotiation succeeded, False otherwise.
        """
        # Read negotiation request
        request = self.read_message(force_json=True)
        if not request or request.get("type") != "protocol_negotiation":
            return False
        
        supported = request.get("supported", ["json"])
        preferred = request.get("preferred", "json")
        
        # Select protocol based on what's available
        if MSGPACK_AVAILABLE and "msgpack" in supported:
            selected = "msgpack"
        else:
            selected = "json"
        
        # Send negotiation response
        response = {
            "type": "protocol_selected",
            "protocol": selected,
            "timestamp": datetime.now().isoformat()
        }
        
        if self.write_message(response, force_json=True):
            self._negotiated_protocol = selected
            return True
        
        return False
    
    def read_message(self, force_json: bool = False) -> Optional[Dict[str, Any]]:
        """
        Read a message from stdin using 4-byte length protocol.
        
        Args:
            force_json: If True, always decode as JSON (used for negotiation)
        """
        try:
            # Read 4-byte length header
            length_data = sys.stdin.buffer.read(4)
            if len(length_data) != 4:
                # EOF or pipe closed, return empty dict to signal shutdown
                return {}
            
            # Unpack length (big-endian)
            length = struct.unpack('>I', length_data)[0]
            
            # Read payload
            payload_data = sys.stdin.buffer.read(length)
            if len(payload_data) != length:
                return {}
            
            # Decode based on protocol
            protocol = "json" if force_json else self._get_active_protocol()
            
            if protocol == "msgpack" and MSGPACK_AVAILABLE:
                try:
                    # Use raw=True to preserve binary data, then convert strings manually
                    result = msgpack.unpackb(payload_data, raw=True, strict_map_key=False)
                    # Convert byte strings to strings where needed for protocol fields
                    result = self._convert_msgpack_strings(result)
                    return result
                except Exception as e:
                    safe_print(f"MessagePack unpack failed: {e}, falling back to JSON")
                    # Fall through to JSON
            
            return json.loads(payload_data.decode('utf-8'))
            
        except (BrokenPipeError, IOError, OSError):
            # Pipe closed, return empty dict to signal shutdown
            return {}
        except Exception as e:
            safe_print(f"Error reading message: {e}")
            return None
    
    def write_message(self, message: Dict[str, Any], force_json: bool = False) -> bool:
        """
        Write a message to stdout using the 4-byte length protocol.
        
        Args:
            force_json: If True, always encode as JSON (used for negotiation)
        """
        try:
            # Encode based on protocol
            protocol = "json" if force_json else self._get_active_protocol()
            
            if protocol == "msgpack" and MSGPACK_AVAILABLE:
                payload_data = msgpack.packb(message, use_bin_type=True)
            else:
                payload_data = json.dumps(message, separators=(',', ':')).encode('utf-8')
            
            # Write length header (big-endian)
            length = struct.pack('>I', len(payload_data))
            sys.stdout.buffer.write(length)
            
            # Write payload
            sys.stdout.buffer.write(payload_data)
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
        # Perform protocol negotiation if in auto mode
        if self.protocol == "auto":
            if not self._negotiate_protocol():
                if not self.quiet:
                    safe_print("Protocol negotiation failed, defaulting to JSON")
                self._negotiated_protocol = "json"
        
        # Only print startup message if not in quiet mode and stderr is still connected
        if not self.quiet:
            protocol_name = self._get_active_protocol().upper()
            if not os.isatty(sys.stderr.fileno()):
                try:
                    # Check if we can write to stderr
                    sys.stderr.write("")
                    sys.stderr.flush()
                    safe_print(f"Snakepit Bridge started in pool-worker mode (protocol: {protocol_name})")
                except:
                    # stderr is closed, skip the message
                    pass
            else:
                safe_print(f"Snakepit Bridge started in pool-worker mode (protocol: {protocol_name})")
        
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


def setup_graceful_shutdown(protocol_handler: ProtocolHandler):
    """
    Set up graceful shutdown handlers for the protocol handler.
    
    This is a utility function that can be used by bridge entry points
    to handle SIGTERM and SIGINT signals properly.
    """
    def graceful_shutdown_handler(signum, frame):
        """Handle SIGTERM by requesting shutdown and exiting cleanly."""
        # Request shutdown of the main loop
        protocol_handler.request_shutdown()
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


def setup_broken_pipe_suppression():
    """
    Set up global broken pipe error suppression.
    
    This is a utility function that can be used by bridge entry points
    to suppress broken pipe errors on shutdown.
    """
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