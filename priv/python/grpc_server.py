#!/usr/bin/env python3
"""
Stateless gRPC bridge server for DSPex.

This server acts as a proxy for state operations (forwarding to Elixir)
and as an execution environment for Python tools.
"""

import argparse
import asyncio
import grpc
import logging
import signal
import sys
from concurrent import futures
from datetime import datetime
from typing import Optional

# Add the package to Python path
sys.path.insert(0, '.')

from snakepit_bridge import snakepit_bridge_pb2 as pb2
from snakepit_bridge import snakepit_bridge_pb2_grpc as pb2_grpc
from snakepit_bridge.session_context import SessionContext
from google.protobuf.timestamp_pb2 import Timestamp
import json

logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)
logger = logging.getLogger(__name__)


class SnakepitBridgeServicer(pb2_grpc.SnakepitBridgeServicer):
    """
    Stateless implementation of the gRPC bridge service.
    
    For state operations, this server acts as a proxy to the Elixir BridgeServer.
    For tool execution, it creates ephemeral contexts that callback to Elixir for state.
    """
    
    def __init__(self, adapter_class, elixir_address: str):
        self.adapter_class = adapter_class
        self.elixir_address = elixir_address
        self.server: Optional[grpc.aio.Server] = None
        
        # Create a client channel to the Elixir server
        self.elixir_channel = grpc.aio.insecure_channel(elixir_address)
        self.elixir_stub = pb2_grpc.SnakepitBridgeStub(self.elixir_channel)
        
        logger.info(f"Python server initialized with Elixir backend at {elixir_address}")
    
    async def close(self):
        """Clean up resources."""
        if self.elixir_channel:
            await self.elixir_channel.close()
    
    # Health & Session Management
    
    async def Ping(self, request, context):
        """Health check endpoint - handled locally."""
        logger.debug(f"Ping received: {request.message}")
        
        response = pb2.PingResponse()
        response.message = f"Pong from Python: {request.message}"
        
        # Set current timestamp
        timestamp = Timestamp()
        timestamp.GetCurrentTime()
        response.server_time.CopyFrom(timestamp)
        
        return response
    
    async def InitializeSession(self, request, context):
        """
        Initialize a session - proxy to Elixir.
        
        The Python server maintains no session state.
        All session data is managed by Elixir.
        """
        logger.info(f"Proxying InitializeSession for: {request.session_id}")
        return await self.elixir_stub.InitializeSession(request)
    
    async def CleanupSession(self, request, context):
        """Clean up a session - proxy to Elixir."""
        logger.info(f"Proxying CleanupSession for: {request.session_id}")
        return await self.elixir_stub.CleanupSession(request)
    
    # Variable Operations - All Proxied to Elixir
    
    async def RegisterVariable(self, request, context):
        """Register a variable - proxy to Elixir."""
        logger.debug(f"Proxying RegisterVariable: {request.name}")
        return await self.elixir_stub.RegisterVariable(request)
    
    async def GetVariable(self, request, context):
        """Get a variable - proxy to Elixir."""
        logger.debug(f"Proxying GetVariable: {request.variable_identifier}")
        return await self.elixir_stub.GetVariable(request)
    
    async def SetVariable(self, request, context):
        """Set a variable - proxy to Elixir."""
        logger.debug(f"Proxying SetVariable: {request.variable_identifier}")
        return await self.elixir_stub.SetVariable(request)
    
    async def GetVariables(self, request, context):
        """Get multiple variables - proxy to Elixir."""
        logger.debug(f"Proxying GetVariables for {len(request.variable_identifiers)} variables")
        return await self.elixir_stub.GetVariables(request)
    
    async def SetVariables(self, request, context):
        """Set multiple variables - proxy to Elixir."""
        logger.debug(f"Proxying SetVariables for {len(request.updates)} variables")
        return await self.elixir_stub.SetVariables(request)
    
    async def ListVariables(self, request, context):
        """List variables - proxy to Elixir."""
        logger.debug(f"Proxying ListVariables with pattern: {request.pattern}")
        return await self.elixir_stub.ListVariables(request)
    
    async def DeleteVariable(self, request, context):
        """Delete a variable - proxy to Elixir."""
        logger.debug(f"Proxying DeleteVariable: {request.variable_identifier}")
        return await self.elixir_stub.DeleteVariable(request)
    
    # Tool Execution - Stateless with Ephemeral Context
    
    async def ExecuteTool(self, request, context):
        """
        Execute a tool with an ephemeral session context.
        
        This is where Python-specific functionality is implemented.
        The context provides access to variables via callbacks to Elixir.
        """
        logger.info(f"ExecuteTool: {request.tool_name} for session {request.session_id}")
        
        try:
            # Create ephemeral context for this request
            session_context = SessionContext(self.elixir_stub, request.session_id)
            
            # Create adapter instance for this request
            adapter = self.adapter_class()
            adapter.set_session_context(session_context)
            
            # Initialize adapter if needed
            if hasattr(adapter, 'initialize'):
                await adapter.initialize()
            
            # Execute the tool
            if hasattr(adapter, 'execute_tool'):
                result = await adapter.execute_tool(
                    tool_name=request.tool_name,
                    arguments=dict(request.arguments),
                    context=session_context
                )
                
                # Build response
                response = pb2.ExecuteToolResponse()
                response.success = True
                response.result_json = json.dumps(result)
                return response
            else:
                # Tool execution not implemented yet
                context.set_code(grpc.StatusCode.UNIMPLEMENTED)
                context.set_details(f'Tool execution not implemented in adapter')
                return pb2.ExecuteToolResponse()
                
        except Exception as e:
            logger.error(f"ExecuteTool failed: {e}", exc_info=True)
            response = pb2.ExecuteToolResponse()
            response.success = False
            response.error_message = str(e)
            return response
    
    async def ExecuteStreamingTool(self, request, context):
        """Execute a streaming tool - placeholder for Stage 3."""
        context.set_code(grpc.StatusCode.UNIMPLEMENTED)
        context.set_details('ExecuteStreamingTool not implemented until Stage 3')
        # For streaming RPCs, we need to yield, not return
        return
        yield  # Make this a generator but never actually yield anything
    
    async def WatchVariables(self, request, context):
        """Watch variables for changes - placeholder for Stage 3."""
        context.set_code(grpc.StatusCode.UNIMPLEMENTED)
        context.set_details('WatchVariables not implemented until Stage 3')
        # For streaming RPCs, we need to yield, not return
        return
        yield  # Make this a generator but never actually yield anything
    
    # Advanced Features - Stage 4 Placeholders
    
    async def AddDependency(self, request, context):
        """Add dependency - proxy to Elixir when implemented."""
        logger.debug("Proxying AddDependency")
        return await self.elixir_stub.AddDependency(request)
    
    async def StartOptimization(self, request, context):
        """Start optimization - proxy to Elixir when implemented."""
        logger.debug("Proxying StartOptimization")
        return await self.elixir_stub.StartOptimization(request)
    
    async def StopOptimization(self, request, context):
        """Stop optimization - proxy to Elixir when implemented."""
        logger.debug("Proxying StopOptimization")
        return await self.elixir_stub.StopOptimization(request)
    
    async def GetVariableHistory(self, request, context):
        """Get variable history - proxy to Elixir when implemented."""
        logger.debug("Proxying GetVariableHistory")
        return await self.elixir_stub.GetVariableHistory(request)
    
    async def RollbackVariable(self, request, context):
        """Rollback variable - proxy to Elixir when implemented."""
        logger.debug("Proxying RollbackVariable")
        return await self.elixir_stub.RollbackVariable(request)
    
    def set_server(self, server):
        """Set the server reference for graceful shutdown."""
        self.server = server


async def serve(port: int, adapter_module: str, elixir_address: str):
    """Start the stateless gRPC server."""
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
    
    servicer = SnakepitBridgeServicer(adapter_class, elixir_address)
    servicer.set_server(server)
    
    pb2_grpc.add_SnakepitBridgeServicer_to_server(servicer, server)
    
    # Listen on port
    actual_port = server.add_insecure_port(f'[::]:{port}')
    
    if actual_port == 0 and port != 0:
        logger.error(f"Failed to bind to port {port}")
        sys.exit(1)
    
    await server.start()
    
    # Signal that the server is ready
    print(f"GRPC_READY:{actual_port}", flush=True)
    logger.info(f"gRPC server started on port {actual_port}")
    logger.info(f"Connected to Elixir backend at {elixir_address}")
    
    # Setup graceful shutdown
    async def _graceful_shutdown():
        logger.info("Shutting down gRPC server...")
        await servicer.close()
        await server.stop(grace_period=5)
        logger.info("Server shutdown complete")
    
    # Handle signals
    loop = asyncio.get_event_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(
            sig,
            lambda: asyncio.create_task(_graceful_shutdown())
        )
    
    try:
        await server.wait_for_termination()
    except asyncio.CancelledError:
        pass
    finally:
        await servicer.close()


async def shutdown(server):
    """Gracefully shutdown the server."""
    await server.stop(grace_period=5)


def main():
    parser = argparse.ArgumentParser(description='DSPex gRPC Bridge Server')
    parser.add_argument('--port', type=int, default=0,
                        help='Port to listen on (0 for dynamic allocation)')
    parser.add_argument('--adapter', type=str, required=True,
                        help='Python module path to adapter class')
    parser.add_argument('--elixir-address', type=str, required=True,
                        help='Address of the Elixir gRPC server (e.g., localhost:50051)')
    
    args = parser.parse_args()
    
    asyncio.run(serve(args.port, args.adapter, args.elixir_address))


if __name__ == '__main__':
    main()