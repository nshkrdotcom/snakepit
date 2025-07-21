#!/usr/bin/env python3
"""
DSPy gRPC adapter for Snakepit.

This adapter provides DSPy functionality over gRPC transport.
"""

import sys
import json
import time
from typing import Dict, Any, Iterator

from ..core import BaseCommandHandler

# Import the DSPy bridge for command handling
sys.path.append('/home/home/p/g/n/dspex/priv/python')
from dspy_bridge import DSPyBridge


class DSPyGRPCHandler(BaseCommandHandler):
    """
    gRPC command handler that integrates with DSPy.
    """
    
    def __init__(self):
        super().__init__()
        # Initialize DSPy bridge in pool-worker mode for gRPC
        self.dspy_bridge = DSPyBridge(mode="pool-worker", worker_id="grpc_worker")
        print(f"[DSPyGRPCHandler] Initialized with DSPy bridge", file=sys.stderr, flush=True)
    
    def _register_commands(self):
        """Register all DSPy commands."""
        # Basic commands from parent
        self.register_command("ping", self.handle_ping)
        self.register_command("echo", self.handle_echo)
        
        # Enhanced Python API command (for Snakepit.Python.call)
        self.register_command("call", self.handle_call)
        self.register_command("store", self.handle_store)
        self.register_command("retrieve", self.handle_retrieve)
        self.register_command("list_stored", self.handle_list_stored)
        self.register_command("delete_stored", self.handle_delete_stored)
        
        # DSPy-specific commands (for direct bridge usage)
        dspy_commands = [
            'configure_lm',
            'create_program', 
            'create_gemini_program',
            'execute_program',
            'execute_gemini_program',
            'list_programs',
            'delete_program',
            'get_stats',
            'cleanup',
            'reset_state',
            'get_program_info',
            'cleanup_session',
            'shutdown'
        ]
        
        for cmd in dspy_commands:
            self.register_command(cmd, self._create_dspy_handler(cmd))
    
    def _create_dspy_handler(self, command_name):
        """Create a handler function that delegates to DSPy bridge."""
        def handler(args: Dict[str, Any]) -> Dict[str, Any]:
            print(f"[DSPyGRPCHandler] Handling command: {command_name} with args: {args}", file=sys.stderr, flush=True)
            try:
                result = self.dspy_bridge.handle_command(command_name, args)
                print(f"[DSPyGRPCHandler] Command {command_name} result: {result}", file=sys.stderr, flush=True)
                return result
            except Exception as e:
                print(f"[DSPyGRPCHandler] Command {command_name} error: {e}", file=sys.stderr, flush=True)
                raise
        return handler
    
    def handle_ping(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Enhanced ping that also checks DSPy status."""
        base_ping = self.dspy_bridge.ping(args)
        return {
            **base_ping,
            "handler": "DSPyGRPCHandler",
            "transport": "grpc"
        }
    
    def handle_echo(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Echo command."""
        return {"echoed": args}
    
    def handle_call(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Handle dynamic Python calls for Snakepit.Python.call API."""
        target = args.get('target')
        kwargs = args.get('kwargs', {})
        store_as = args.get('store_as')
        
        print(f"[DSPyGRPCHandler] handle_call: target={target}, kwargs={kwargs}, store_as={store_as}", file=sys.stderr, flush=True)
        
        # Map common DSPy calls to the bridge commands
        if target == "dspy.configure":
            # DSPy configuration
            lm = kwargs.get('lm', '')
            if lm.startswith('stored.'):
                # Reference to stored LM - need to handle this specially
                return {"result": {"status": "configured"}}
            else:
                return {"error": "LM configuration requires stored LM reference"}
        
        elif target == "dspy.LM":
            # Create language model
            # Ensure we pass provider as 'google' for Gemini models
            if 'model' in kwargs and kwargs['model'].startswith('gemini/'):
                kwargs['provider'] = 'google'
            
            result = self.dspy_bridge.handle_command('configure_lm', kwargs)
            if store_as and 'error' not in result:
                # Store the LM reference
                self._store_object(store_as, {"type": "lm", "config": kwargs})
            return {"result": result}
        
        elif target == "dspy.Predict":
            # Create Predict module
            signature = kwargs.get('signature', 'question -> answer')
            # Parse the signature string to create proper definition
            signature_def = self._parse_signature(signature)
            
            # For pool-worker mode, use anonymous session
            result = self.dspy_bridge.handle_command('create_program', {
                'id': store_as or f'predict_{id(self)}',
                'signature': signature_def,
                'program_type': 'predict',
                'session_id': 'anonymous'  # Use anonymous session for pool-worker mode
            })
            return {"result": result}
        
        elif target == "dspy.ChainOfThought":
            # Create ChainOfThought module
            signature = kwargs.get('signature', 'question -> answer')
            # Parse the signature string to create proper definition
            signature_def = self._parse_signature(signature)
            
            result = self.dspy_bridge.handle_command('create_program', {
                'id': store_as or f'cot_{id(self)}',
                'signature': signature_def,
                'program_type': 'chain_of_thought',
                'session_id': 'anonymous'  # Use anonymous session for pool-worker mode
            })
            return {"result": result}
        
        elif target.startswith("stored.") and target.endswith(".__call__"):
            # Execute stored program
            program_id = target[7:-9]  # Remove "stored." and ".__call__"
            result = self.dspy_bridge.handle_command('execute_program', {
                'program_id': program_id,
                'inputs': kwargs,
                'session_id': 'anonymous'  # Use anonymous session for pool-worker mode
            })
            return {"result": result}
        
        else:
            # Unknown target
            return {"error": f"Unknown call target: {target}"}
    
    def handle_store(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Store an object."""
        obj_id = args.get('id')
        value = args.get('value')
        self._store_object(obj_id, value)
        return {"result": {"stored": obj_id}}
    
    def handle_retrieve(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Retrieve a stored object."""
        obj_id = args.get('id')
        value = self._get_object(obj_id)
        if value is not None:
            return {"result": value}
        else:
            return {"error": f"Object not found: {obj_id}"}
    
    def handle_list_stored(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """List stored objects."""
        if hasattr(self, '_stored_objects'):
            return {"result": list(self._stored_objects.keys())}
        else:
            return {"result": []}
    
    def handle_delete_stored(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Delete a stored object."""
        obj_id = args.get('id')
        if hasattr(self, '_stored_objects') and obj_id in self._stored_objects:
            del self._stored_objects[obj_id]
            return {"result": {"deleted": obj_id}}
        else:
            return {"error": f"Object not found: {obj_id}"}
    
    def _store_object(self, obj_id, value):
        """Internal method to store objects."""
        if not hasattr(self, '_stored_objects'):
            self._stored_objects = {}
        self._stored_objects[obj_id] = value
    
    def _get_object(self, obj_id):
        """Internal method to get stored objects."""
        if hasattr(self, '_stored_objects'):
            return self._stored_objects.get(obj_id)
        return None
    
    def _parse_signature(self, signature_str):
        """Parse a DSPy signature string into a structured definition."""
        # Simple parser for "input1, input2 -> output1, output2" format
        if "->" in signature_str:
            inputs_str, outputs_str = signature_str.split("->", 1)
            inputs = [{'name': name.strip()} for name in inputs_str.split(",") if name.strip()]
            outputs = [{'name': name.strip()} for name in outputs_str.split(",") if name.strip()]
        else:
            # No arrow, assume it's just an output
            inputs = []
            outputs = [{'name': signature_str.strip()}]
        
        return {
            'inputs': inputs,
            'outputs': outputs
        }
    
    def get_supported_commands(self) -> list:
        """Get all supported commands including DSPy ones."""
        basic_commands = super().get_supported_commands()
        
        # Enhanced Python API commands
        enhanced_commands = [
            'call',
            'store',
            'retrieve',
            'list_stored',
            'delete_stored'
        ]
        
        dspy_commands = [
            'configure_lm',
            'create_program',
            'create_gemini_program', 
            'execute_program',
            'execute_gemini_program',
            'list_programs',
            'delete_program',
            'get_stats',
            'cleanup',
            'reset_state',
            'get_program_info',
            'cleanup_session',
            'shutdown'
        ]
        # Also include streaming commands if needed
        streaming_commands = ["ping_stream"]
        return basic_commands + enhanced_commands + dspy_commands + streaming_commands
    
    def process_stream_command(self, command: str, args: Dict[str, Any]) -> Iterator[Dict[str, Any]]:
        """
        Handle streaming commands.
        
        For now, just basic streaming support. DSPy commands are non-streaming.
        """
        print(f"[DSPyGRPCHandler] process_stream_command called with command: {command}, args: {args}", file=sys.stderr, flush=True)
        
        if command == "ping_stream":
            yield from self._handle_ping_stream(args)
        else:
            # Unknown streaming command
            print(f"[DSPyGRPCHandler] Unknown streaming command: {command}", file=sys.stderr, flush=True)
            yield {
                "data": {"error": f"Unknown streaming command: {command}"},
                "is_final": True,
                "error": f"Unknown streaming command: {command}"
            }
    
    def _handle_ping_stream(self, args: Dict[str, Any]) -> Iterator[Dict[str, Any]]:
        """Stream ping responses."""
        count = args.get('count', 5)
        interval = args.get('interval', 0.5)
        
        print(f"[DSPyGRPCHandler] Starting ping stream with count={count}, interval={interval}", file=sys.stderr, flush=True)
        
        for i in range(count):
            chunk_data = {
                "data": {
                    "ping_number": str(i + 1),
                    "timestamp": str(time.time()),
                    "message": f"Ping {i + 1} of {count}",
                    "dspy_available": str(self.dspy_bridge.ping({}).get('dspy_available', False))
                },
                "is_final": i == count - 1
            }
            print(f"[DSPyGRPCHandler] Yielding ping chunk {i + 1}: {chunk_data}", file=sys.stderr, flush=True)
            yield chunk_data
            
            if i < count - 1:
                time.sleep(interval)
        
        print(f"[DSPyGRPCHandler] Ping stream completed", file=sys.stderr, flush=True)