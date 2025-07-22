#!/usr/bin/env python3
"""
Unified gRPC bridge server for DSPex.
"""

import argparse
import asyncio
import grpc
import logging
import signal
import sys
from concurrent import futures
from datetime import datetime
from typing import Dict, Optional

# Add the package to Python path
sys.path.insert(0, '.')

from snakepit_bridge import snakepit_bridge_pb2 as pb2
from snakepit_bridge import snakepit_bridge_pb2_grpc as pb2_grpc
from snakepit_bridge.session_context import SessionContext
from snakepit_bridge.serialization import TypeSerializer
from google.protobuf.timestamp_pb2 import Timestamp
from google.protobuf import any_pb2
import json

logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)
logger = logging.getLogger(__name__)


class SnakepitBridgeServicer(pb2_grpc.SnakepitBridgeServicer):
    """Implementation of the unified gRPC bridge service."""
    
    def __init__(self, adapter_class):
        self.adapter_class = adapter_class
        self.sessions: Dict[str, SessionContext] = {}
        self.adapters: Dict[str, object] = {}
        self.server: Optional[grpc.aio.Server] = None
    
    async def Ping(self, request, context):
        """Health check endpoint."""
        logger.debug(f"Ping received: {request.message}")
        
        response = pb2.PingResponse()
        response.message = f"Pong: {request.message}"
        
        # Set current timestamp
        timestamp = Timestamp()
        timestamp.GetCurrentTime()
        response.server_time.CopyFrom(timestamp)
        
        return response
    
    async def InitializeSession(self, request, context):
        """Initialize a new session."""
        logger.info(f"Initializing session: {request.session_id}")
        
        try:
            # Create session context with config
            config = {
                'enable_caching': request.config.enable_caching,
                'cache_ttl': request.config.cache_ttl_seconds,
                'enable_telemetry': request.config.enable_telemetry,
                'metadata': dict(request.metadata)
            }
            
            session = SessionContext(request.session_id, config)
            self.sessions[request.session_id] = session
            
            # Create adapter instance
            adapter = self.adapter_class()
            adapter.set_session_context(session)
            self.adapters[request.session_id] = adapter
            
            # Initialize adapter (may register tools/variables)
            if hasattr(adapter, 'initialize'):
                await adapter.initialize()
            
            response = pb2.InitializeSessionResponse()
            response.success = True
            
            # Populate available tools
            for tool_name, tool_spec in session.get_tools().items():
                proto_spec = pb2.ToolSpec()
                proto_spec.name = tool_name
                proto_spec.description = tool_spec.get('description', '')
                proto_spec.supports_streaming = tool_spec.get('supports_streaming', False)
                response.available_tools[tool_name].CopyFrom(proto_spec)
            
            return response
            
        except Exception as e:
            logger.error(f"Failed to initialize session: {e}", exc_info=True)
            response = pb2.InitializeSessionResponse()
            response.success = False
            response.error_message = str(e)
            return response
    
    async def CleanupSession(self, request, context):
        """Clean up a session."""
        logger.info(f"Cleaning up session: {request.session_id}")
        
        response = pb2.CleanupSessionResponse()
        resources_cleaned = 0
        
        if request.session_id in self.sessions:
            session = self.sessions[request.session_id]
            
            # Clean up adapter
            if request.session_id in self.adapters:
                adapter = self.adapters[request.session_id]
                if hasattr(adapter, 'cleanup'):
                    await adapter.cleanup()
                del self.adapters[request.session_id]
                resources_cleaned += 1
            
            # Clean up session
            await session.cleanup()
            del self.sessions[request.session_id]
            resources_cleaned += 1
            
            response.success = True
        else:
            response.success = False
            
        response.resources_cleaned = resources_cleaned
        return response
    
    async def RegisterVariable(self, request, context):
        """Register a new variable."""
        session = self._get_session(request.session_id, context)
        if not session:
            return pb2.RegisterVariableResponse()
        
        try:
            # Decode initial value
            logger.info(f"Decoding value of type {request.type}")
            value = TypeSerializer.decode_any(request.initial_value)
            logger.info(f"Decoded value: {value}")
            
            # Parse constraints
            constraints = {}
            if request.constraints_json:
                constraints = json.loads(request.constraints_json)
                logger.info(f"Parsed constraints: {constraints}")
            
            # Register the variable
            logger.info(f"Registering variable: {request.name}")
            var_id = session.register_variable(
                name=request.name,
                var_type=request.type,
                initial_value=value,
                constraints=constraints,
                metadata=dict(request.metadata)
            )
            
            # Get the variable to return
            variable = session.get_variable_by_id(var_id)
            
            if not variable:
                logger.error(f"Variable not found after registration: {var_id}")
                context.set_code(grpc.StatusCode.INTERNAL)
                context.set_details("Failed to retrieve variable after registration")
                return pb2.RegisterVariableResponse()
            
            response = pb2.RegisterVariableResponse()
            response.success = True
            response.variable_id = var_id
            
            return response
            
        except Exception as e:
            logger.error(f"RegisterVariable failed: {e}", exc_info=True)
            context.set_code(grpc.StatusCode.INVALID_ARGUMENT)
            # Make sure we're not getting a simple 'variable' error
            error_msg = str(e)
            if error_msg == "variable":
                # Try to provide more context
                error_msg = f"Variable conversion error: {repr(e)}"
            context.set_details(error_msg)
            return pb2.RegisterVariableResponse()
    
    async def GetVariable(self, request, context):
        """Get a variable value."""
        session = self._get_session(request.session_id, context)
        if not session:
            return pb2.GetVariableResponse()
        
        try:
            # Get by name or ID based on variable_identifier
            identifier = request.variable_identifier
            if not identifier:
                context.set_code(grpc.StatusCode.INVALID_ARGUMENT)
                context.set_details("variable_identifier must be provided")
                return pb2.GetVariableResponse()
            
            # Check if it's an ID (starts with "var_") or a name
            if identifier.startswith("var_"):
                variable = session.get_variable_by_id(identifier)
            else:
                variable = session.get_variable_by_name(identifier)
            
            if not variable:
                context.set_code(grpc.StatusCode.NOT_FOUND)
                context.set_details("Variable not found")
                return pb2.GetVariableResponse()
            
            response = pb2.GetVariableResponse()
            response.variable.CopyFrom(self._convert_to_proto_variable(variable))
            return response
            
        except Exception as e:
            logger.error(f"GetVariable failed: {e}", exc_info=True)
            context.set_code(grpc.StatusCode.INTERNAL)
            context.set_details(str(e))
            return pb2.GetVariableResponse()
    
    async def SetVariable(self, request, context):
        """Set a variable value."""
        session = self._get_session(request.session_id, context)
        if not session:
            return pb2.SetVariableResponse()
        
        try:
            # Decode new value
            value = TypeSerializer.decode_any(request.value)
            
            # Update variable using variable_identifier
            identifier = request.variable_identifier
            if not identifier:
                context.set_code(grpc.StatusCode.INVALID_ARGUMENT)
                context.set_details("variable_identifier must be provided")
                return pb2.SetVariableResponse()
            
            # For now, we assume identifier is always a name (not an ID)
            success = session.set_variable(
                name=identifier,
                value=value,
                metadata=dict(request.metadata)
            )
            
            response = pb2.SetVariableResponse()
            response.success = success
            
            if not success:
                response.error = "Failed to set variable"
            
            return response
            
        except Exception as e:
            logger.error(f"SetVariable failed: {e}", exc_info=True)
            context.set_code(grpc.StatusCode.INVALID_ARGUMENT)
            context.set_details(str(e))
            return pb2.SetVariableResponse()
    
    async def GetVariables(self, request, context):
        """Get multiple variables at once."""
        session = self._get_session(request.session_id, context)
        if not session:
            return pb2.BatchGetVariablesResponse()
        
        response = pb2.BatchGetVariablesResponse()
        
        for name in request.names:
            try:
                variable = session.get_variable_by_name(name)
                if variable:
                    response.variables[name].CopyFrom(self._convert_to_proto_variable(variable))
                else:
                    # Add error for missing variable
                    response.errors[name] = f"Variable '{name}' not found"
            except Exception as e:
                response.errors[name] = str(e)
        
        return response
    
    async def SetVariables(self, request, context):
        """Set multiple variables at once."""
        session = self._get_session(request.session_id, context)
        if not session:
            return pb2.BatchSetVariablesResponse()
        
        response = pb2.BatchSetVariablesResponse()
        
        for update in request.updates:
            try:
                # Decode value
                value = TypeSerializer.decode_any(update.value)
                
                # Update variable
                success = session.set_variable(
                    name=update.name,
                    value=value,
                    metadata=dict(update.metadata)
                )
                
                response.results[update.name] = success
                if not success:
                    response.errors[update.name] = "Failed to set variable"
                    
            except Exception as e:
                response.results[update.name] = False
                response.errors[update.name] = str(e)
        
        return response
    
    async def ExecuteTool(self, request, context):
        """Execute a tool - placeholder for Stage 2."""
        context.set_code(grpc.StatusCode.UNIMPLEMENTED)
        context.set_details('ExecuteTool not implemented until Stage 2')
        return pb2.ExecuteToolResponse()
    
    async def WatchVariables(self, request, context):
        """Watch variables for changes - placeholder for Stage 3."""
        context.set_code(grpc.StatusCode.UNIMPLEMENTED)
        context.set_details('WatchVariables not implemented until Stage 3')
        # Return empty generator to satisfy type requirements
        async def empty_generator():
            return
            yield  # Make it a generator
        return empty_generator()
    
    def set_server(self, server):
        """Set the server reference for graceful shutdown."""
        self.server = server
    
    def _get_session(self, session_id: str, context) -> Optional[SessionContext]:
        """Get session with error handling."""
        if session_id not in self.sessions:
            context.set_code(grpc.StatusCode.NOT_FOUND)
            context.set_details(f"Session {session_id} not found")
            return None
        return self.sessions[session_id]
    
    def _convert_to_proto_variable(self, variable: dict) -> pb2.Variable:
        """Convert internal variable representation to protobuf."""
        proto_var = pb2.Variable()
        proto_var.id = variable['id']
        proto_var.name = variable['name']
        proto_var.type = variable['type']
        proto_var.version = variable['version']
        
        # Encode value
        value_any = TypeSerializer.encode_any(variable['value'], variable['type'])
        # value_any is already a protobuf Any, just copy it
        proto_var.value.CopyFrom(value_any)
        
        # Set timestamp (only last_updated_at in the proto)
        timestamp = Timestamp()
        timestamp.FromDatetime(variable['updated_at'])
        proto_var.last_updated_at.CopyFrom(timestamp)
        
        # Set metadata
        for k, v in variable.get('metadata', {}).items():
            proto_var.metadata[k] = str(v)
        
        # Set constraints
        if variable.get('constraints'):
            proto_var.constraints_json = json.dumps(variable['constraints'])
        
        # Set source (default to PYTHON)
        # TODO: Debug why this is failing
        # proto_var.source = pb2.Variable.Source.PYTHON
        
        return proto_var


async def serve(port: int, adapter_module: str):
    """Start the gRPC server."""
    # Import the adapter
    module_parts = adapter_module.split('.')
    module_name = '.'.join(module_parts[:-1])
    class_name = module_parts[-1]
    
    try:
        module = __import__(module_name, fromlist=[class_name])
        adapter_class = getattr(module, class_name)
    except (ImportError, AttributeError) as e:
        logger.error(f"Failed to import adapter {adapter_module}: {e}")
        sys.exit(1)
    
    # Create server
    server = grpc.aio.server(
        futures.ThreadPoolExecutor(max_workers=10),
        options=[
            ('grpc.max_send_message_length', 100 * 1024 * 1024),  # 100MB
            ('grpc.max_receive_message_length', 100 * 1024 * 1024),
        ]
    )
    
    servicer = SnakepitBridgeServicer(adapter_class)
    servicer.set_server(server)
    
    pb2_grpc.add_SnakepitBridgeServicer_to_server(servicer, server)
    
    # Listen on port
    actual_port = server.add_insecure_port(f'[::]:{port}')
    
    logger.info(f"Starting gRPC server on port {actual_port}")
    await server.start()
    
    # Signal readiness with actual port
    print(f"GRPC_READY:{actual_port}", flush=True)
    
    # Setup graceful shutdown with asyncio signal handlers
    shutdown_event = asyncio.Event()
    
    async def _graceful_shutdown():
        logger.info("Graceful shutdown initiated...")
        # Immediate shutdown for tests - cancels all active RPCs immediately
        await server.stop(0)
        shutdown_event.set()
    
    # Get the current event loop and attach signal handlers
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        # Use asyncio's signal handler instead of standard signal module
        loop.add_signal_handler(sig, lambda: asyncio.create_task(_graceful_shutdown()))
    
    try:
        # Wait for shutdown signal
        await shutdown_event.wait()
        logger.info("gRPC server shut down complete.")
    except asyncio.CancelledError:
        pass
    
    logger.info("Server stopped")


async def shutdown(server):
    """Gracefully shutdown the server."""
    logger.info("Stopping server gracefully...")
    await server.stop(grace=5)


def main():
    parser = argparse.ArgumentParser(description='DSPex gRPC Bridge Server')
    parser.add_argument('--port', type=int, default=50051, 
                       help='Port to listen on')
    parser.add_argument('--adapter', type=str, 
                       default='enhanced_bridge.EnhancedBridge',
                       help='Adapter class to use')
    parser.add_argument('--log-level', type=str, default='INFO',
                       choices=['DEBUG', 'INFO', 'WARNING', 'ERROR'],
                       help='Logging level')
    
    args = parser.parse_args()
    
    # Update logging level
    logging.getLogger().setLevel(getattr(logging, args.log_level))
    
    try:
        asyncio.run(serve(args.port, args.adapter))
    except KeyboardInterrupt:
        logger.info("Server interrupted by user")
    except Exception as e:
        logger.error(f"Server failed: {e}", exc_info=True)
        sys.exit(1)


if __name__ == '__main__':
    main()