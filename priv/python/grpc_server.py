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
import time
import inspect
from concurrent import futures
from datetime import datetime
from typing import Optional

# Add the package to Python path
sys.path.insert(0, '.')

import snakepit_bridge_pb2 as pb2
import snakepit_bridge_pb2_grpc as pb2_grpc
from snakepit_bridge.session_context import SessionContext
from snakepit_bridge.serialization import TypeSerializer
from google.protobuf.timestamp_pb2 import Timestamp
from google.protobuf import any_pb2
import json
import functools
import traceback
import pickle

logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)
logger = logging.getLogger(__name__)


def grpc_error_handler(func):
    """
    Decorator to handle unexpected exceptions in gRPC service methods.
    
    Converts Python exceptions into proper gRPC errors with detailed
    error messages while avoiding exposing sensitive information.
    """
    @functools.wraps(func)
    async def wrapper(self, request, context):
        method_name = func.__name__
        try:
            return await func(self, request, context)
        except grpc.RpcError:
            # Re-raise gRPC errors as-is
            raise
        except ValueError as e:
            # Invalid input errors
            logger.warning(f"{method_name} - ValueError: {str(e)}")
            await context.abort(grpc.StatusCode.INVALID_ARGUMENT, str(e))
        except NotImplementedError as e:
            # Unimplemented features
            logger.info(f"{method_name} - NotImplementedError: {str(e)}")
            await context.abort(grpc.StatusCode.UNIMPLEMENTED, str(e))
        except TimeoutError as e:
            # Timeout errors
            logger.warning(f"{method_name} - TimeoutError: {str(e)}")
            await context.abort(grpc.StatusCode.DEADLINE_EXCEEDED, "Operation timed out")
        except PermissionError as e:
            # Permission errors
            logger.warning(f"{method_name} - PermissionError: {str(e)}")
            await context.abort(grpc.StatusCode.PERMISSION_DENIED, "Permission denied")
        except FileNotFoundError as e:
            # Resource not found
            logger.warning(f"{method_name} - FileNotFoundError: {str(e)}")
            await context.abort(grpc.StatusCode.NOT_FOUND, "Resource not found")
        except Exception as e:
            # Catch-all for unexpected errors
            error_id = f"{method_name}_{int(time.time() * 1000)}"
            logger.error(f"{error_id} - Unexpected error: {type(e).__name__}: {str(e)}")
            logger.error(f"{error_id} - Traceback:\n{traceback.format_exc()}")
            
            # Return a generic error message to avoid exposing internals
            await context.abort(
                grpc.StatusCode.INTERNAL,
                f"Internal server error (ID: {error_id}). Please check server logs for details."
            )
    
    # Handle both sync and async functions
    if asyncio.iscoroutinefunction(func):
        return wrapper
    else:
        @functools.wraps(func)
        def sync_wrapper(self, request, context):
            method_name = func.__name__
            try:
                return func(self, request, context)
            except grpc.RpcError:
                raise
            except ValueError as e:
                logger.warning(f"{method_name} - ValueError: {str(e)}")
                context.abort(grpc.StatusCode.INVALID_ARGUMENT, str(e))
            except NotImplementedError as e:
                logger.info(f"{method_name} - NotImplementedError: {str(e)}")
                context.abort(grpc.StatusCode.UNIMPLEMENTED, str(e))
            except Exception as e:
                error_id = f"{method_name}_{int(time.time() * 1000)}"
                logger.error(f"{error_id} - Unexpected error: {type(e).__name__}: {str(e)}")
                logger.error(f"{error_id} - Traceback:\n{traceback.format_exc()}")
                context.abort(
                    grpc.StatusCode.INTERNAL,
                    f"Internal server error (ID: {error_id}). Please check server logs for details."
                )
        return sync_wrapper


class BridgeServiceServicer(pb2_grpc.BridgeServiceServicer):
    """
    Stateless implementation of the gRPC bridge service.
    
    For state operations, this server acts as a proxy to the Elixir BridgeServer.
    For tool execution, it creates ephemeral contexts that callback to Elixir for state.
    """
    
    def __init__(self, adapter_class, elixir_address: str):
        self.adapter_class = adapter_class
        self.elixir_address = elixir_address
        self.server: Optional[grpc.aio.Server] = None
        
        # Create async client channel for async operations (proxying)
        self.elixir_channel = grpc.aio.insecure_channel(elixir_address)
        self.elixir_stub = pb2_grpc.BridgeServiceStub(self.elixir_channel)
        
        # Create sync client channel for SessionContext
        self.sync_elixir_channel = grpc.insecure_channel(elixir_address)
        self.sync_elixir_stub = pb2_grpc.BridgeServiceStub(self.sync_elixir_channel)
        
        logger.info(f"Python server initialized with Elixir backend at {elixir_address}")
    
    async def close(self):
        """Clean up resources."""
        if self.elixir_channel:
            await self.elixir_channel.close()
        if self.sync_elixir_channel:
            self.sync_elixir_channel.close()
    
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
    
    async def GetSession(self, request, context):
        """Get session details - proxy to Elixir."""
        logger.debug(f"Proxying GetSession for: {request.session_id}")
        return await self.elixir_stub.GetSession(request)
    
    async def Heartbeat(self, request, context):
        """Send heartbeat - proxy to Elixir."""
        logger.debug(f"Proxying Heartbeat for: {request.session_id}")
        return await self.elixir_stub.Heartbeat(request)
    
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
    
    @grpc_error_handler
    async def ExecuteTool(self, request, context):
        """Executes a non-streaming tool."""
        logger.info(f"ExecuteTool: {request.tool_name} for session {request.session_id}")
        start_time = time.time()
        
        try:
            # Ensure session exists in Elixir
            init_request = pb2.InitializeSessionRequest(session_id=request.session_id)
            try:
                self.sync_elixir_stub.InitializeSession(init_request)
            except grpc.RpcError as e:
                # Session might already exist, that's ok
                if e.code() != grpc.StatusCode.ALREADY_EXISTS:
                    logger.debug(f"InitializeSession for {request.session_id}: {e}")
            
            # Create ephemeral context for this request
            session_context = SessionContext(self.sync_elixir_stub, request.session_id)
            
            # Create adapter instance for this request
            adapter = self.adapter_class()
            adapter.set_session_context(session_context)
            
            # Register adapter tools with the session (for new BaseAdapter)
            if hasattr(adapter, 'register_with_session'):
                registered_tools = adapter.register_with_session(request.session_id, self.sync_elixir_stub)
                logger.info(f"Registered {len(registered_tools)} tools for session {request.session_id}")
            
            # Initialize adapter if needed
            if hasattr(adapter, 'initialize'):
                await adapter.initialize()
            
            # Decode parameters from protobuf Any using TypeSerializer
            arguments = {key: TypeSerializer.decode_any(any_msg) for key, any_msg in request.parameters.items()}
            # Also handle binary parameters if present
            for key, binary_val in request.binary_parameters.items():
                arguments[key] = pickle.loads(binary_val)
            
            # Execute the tool
            if not hasattr(adapter, 'execute_tool'):
                raise grpc.RpcError(grpc.StatusCode.UNIMPLEMENTED, "Adapter does not support 'execute_tool'")
            
            # CORRECT: Await the async method
            import inspect
            if inspect.iscoroutinefunction(adapter.execute_tool):
                result_data = await adapter.execute_tool(
                    tool_name=request.tool_name,
                    arguments=arguments,
                    context=session_context
                )
            else:
                result_data = adapter.execute_tool(
                    tool_name=request.tool_name,
                    arguments=arguments,
                    context=session_context
                )
            
            # Check if a generator was mistakenly returned (should have been called via streaming endpoint)
            if inspect.isgenerator(result_data) or inspect.isasyncgen(result_data):
                logger.warning(f"Tool '{request.tool_name}' returned a generator but was called via non-streaming ExecuteTool. Returning empty result.")
                result_data = {"error": "Streaming tool called on non-streaming endpoint."}
            
            # CORRECT: Use the robust TypeValidator and TypeSerializer for ALL types.
            # This removes the need for custom `snakepit.map` logic.
            response = pb2.ExecuteToolResponse(success=True)
            from snakepit_bridge.types import TypeValidator
            
            # Infer the type of the result
            result_type = TypeValidator.infer_type(result_data)
            
            # Use the centralized serializer to encode the result correctly
            any_msg, binary_data = TypeSerializer.encode_any(result_data, result_type.value)
            
            # The result from encode_any is already a protobuf Any message, so we just assign it
            response.result.CopyFrom(any_msg)
            if binary_data:
                response.binary_result = binary_data
                
            response.execution_time_ms = int((time.time() - start_time) * 1000)
            
            return response
                
        except Exception as e:
            logger.error(f"ExecuteTool failed: {e}", exc_info=True)
            response = pb2.ExecuteToolResponse()
            response.success = False
            response.error_message = str(e)
            return response
    
    @grpc_error_handler
    async def ExecuteStreamingTool(self, request, context):
        """Executes a streaming tool (supports both sync and async generators)."""
        logger.info(f"ExecuteStreamingTool: {request.tool_name} for session {request.session_id}")
        logger.info(f"ExecuteStreamingTool request.stream: {request.stream}")
        
        # Debug logging to file
        with open("/tmp/grpc_streaming_debug.log", "a") as f:
            f.write(f"ExecuteStreamingTool called: {request.tool_name} at {time.time()}\n")
            f.flush()
        
        try:
            # Ensure session exists in Elixir
            init_request = pb2.InitializeSessionRequest(session_id=request.session_id)
            try:
                self.sync_elixir_stub.InitializeSession(init_request)
            except grpc.RpcError as e:
                # Session might already exist, that's ok
                if e.code() != grpc.StatusCode.ALREADY_EXISTS:
                    logger.debug(f"InitializeSession for {request.session_id}: {e}")
            
            # Create ephemeral context for this request
            logger.info(f"Creating SessionContext for {request.session_id}")
            session_context = SessionContext(self.sync_elixir_stub, request.session_id)
            
            # Create adapter instance for this request
            logger.info(f"Creating adapter instance: {self.adapter_class}")
            adapter = self.adapter_class()
            adapter.set_session_context(session_context)
            
            # Register adapter tools with the session (for new BaseAdapter)
            if hasattr(adapter, 'register_with_session'):
                registered_tools = adapter.register_with_session(request.session_id, self.sync_elixir_stub)
                logger.info(f"Registered {len(registered_tools)} tools for session {request.session_id}")
            
            # CRITICAL FIX: Initialize adapter (async-safe now that method is async)
            if hasattr(adapter, 'initialize'):
                if inspect.iscoroutinefunction(adapter.initialize):
                    await adapter.initialize()
                else:
                    adapter.initialize()

            # Decode parameters from protobuf Any using TypeSerializer
            arguments = {key: TypeSerializer.decode_any(any_msg) for key, any_msg in request.parameters.items()}
            # Also handle binary parameters if present
            for key, binary_val in request.binary_parameters.items():
                arguments[key] = pickle.loads(binary_val)

            # Execute the tool
            if not hasattr(adapter, 'execute_tool'):
                await context.abort(grpc.StatusCode.UNIMPLEMENTED, "Adapter does not support tool execution")
                return

            # CRITICAL FIX: Support both sync and async execute_tool
            if inspect.iscoroutinefunction(adapter.execute_tool):
                stream_iterator = await adapter.execute_tool(
                    tool_name=request.tool_name,
                    arguments=arguments,
                    context=session_context
                )
            else:
                stream_iterator = adapter.execute_tool(
                    tool_name=request.tool_name,
                    arguments=arguments,
                    context=session_context
                )
            
            # Handle both sync and async generators
            chunk_id_counter = 0
            
            # Import StreamChunk for proper handling
            from snakepit_bridge.adapters.showcase.tool import StreamChunk
            
            logger.info(f"Stream iterator type: {type(stream_iterator)}")
            logger.info(f"Has __aiter__: {hasattr(stream_iterator, '__aiter__')}")
            logger.info(f"Has __iter__: {hasattr(stream_iterator, '__iter__')}")

            # CRITICAL FIX: Handle both async and sync generators uniformly
            if hasattr(stream_iterator, '__aiter__'):
                # Async generator - use async for
                logger.info(f"Processing async generator for {request.tool_name}")
                with open("/tmp/grpc_streaming_debug.log", "a") as f:
                    f.write(f"Starting async iteration at {time.time()}\n")
                    f.flush()

                async for chunk_data in stream_iterator:
                    logger.info(f"Got async chunk data: {chunk_data}")
                    with open("/tmp/grpc_streaming_debug.log", "a") as f:
                        f.write(f"Got async chunk: {chunk_data} at {time.time()}\n")
                        f.flush()

                    if isinstance(chunk_data, StreamChunk):
                        data_payload = chunk_data.data
                    else:
                        data_payload = chunk_data

                    data_bytes = json.dumps(data_payload).encode('utf-8')
                    chunk_id_counter += 1
                    chunk = pb2.ToolChunk(
                        chunk_id=f"{request.tool_name}-{chunk_id_counter}",
                        data=data_bytes,
                        is_final=False
                    )
                    logger.info(f"Yielding async chunk {chunk_id_counter}: {chunk.chunk_id}")
                    with open("/tmp/grpc_streaming_debug.log", "a") as f:
                        f.write(f"Yielding async chunk_id={chunk.chunk_id} at {time.time()}\n")
                        f.flush()
                    yield chunk

            elif hasattr(stream_iterator, '__iter__'):
                # Sync generator - use regular for
                logger.info(f"Processing sync iterator for {request.tool_name}")
                with open("/tmp/grpc_streaming_debug.log", "a") as f:
                    f.write(f"Starting sync iteration at {time.time()}\n")
                    f.flush()

                for chunk_data in stream_iterator:
                    logger.info(f"Got sync chunk data: {chunk_data}")
                    with open("/tmp/grpc_streaming_debug.log", "a") as f:
                        f.write(f"Got sync chunk: {chunk_data} at {time.time()}\n")
                        f.flush()

                    if isinstance(chunk_data, StreamChunk):
                        data_payload = chunk_data.data
                    else:
                        data_payload = chunk_data

                    data_bytes = json.dumps(data_payload).encode('utf-8')
                    chunk_id_counter += 1
                    chunk = pb2.ToolChunk(
                        chunk_id=f"{request.tool_name}-{chunk_id_counter}",
                        data=data_bytes,
                        is_final=False
                    )
                    logger.info(f"Yielding sync chunk {chunk_id_counter}: {chunk.chunk_id}")
                    with open("/tmp/grpc_streaming_debug.log", "a") as f:
                        f.write(f"Yielding sync chunk_id={chunk.chunk_id} at {time.time()}\n")
                        f.flush()
                    yield chunk

            else:
                # Non-generator return
                logger.info(f"Non-generator return from {request.tool_name}")
                data_bytes = json.dumps(stream_iterator).encode('utf-8')
                yield pb2.ToolChunk(
                    chunk_id=f"{request.tool_name}-1",
                    data=data_bytes,
                    is_final=True
                )
            
            # Yield the final empty chunk after the loop
            logger.info(f"Yielding final chunk for {request.tool_name}")
            with open("/tmp/grpc_streaming_debug.log", "a") as f:
                f.write(f"Yielding final chunk at {time.time()}\n")
                f.flush()
            yield pb2.ToolChunk(is_final=True)
                
        except Exception as e:
            logger.error(f"ExecuteStreamingTool failed: {e}", exc_info=True)
            context.abort(grpc.StatusCode.INTERNAL, str(e))
    
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


async def serve_with_shutdown(port: int, adapter_module: str, elixir_address: str, shutdown_event: asyncio.Event):
    """Start the stateless gRPC server with proper shutdown handling."""
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
    
    servicer = BridgeServiceServicer(adapter_class, elixir_address)
    servicer.set_server(server)
    
    pb2_grpc.add_BridgeServiceServicer_to_server(servicer, server)

    # Listen on port
    actual_port = server.add_insecure_port(f'[::]:{port}')
    
    if actual_port == 0 and port != 0:
        logger.error(f"Failed to bind to port {port}")
        sys.exit(1)

    await server.start()

    # Signal that the server is ready
    # CRITICAL: Use logger instead of print() for reliable capture via :stderr_to_stdout
    logger.info(f"GRPC_READY:{actual_port}")

    logger.info(f"gRPC server started on port {actual_port}")
    logger.info(f"Connected to Elixir backend at {elixir_address}")
    
    # The shutdown_event is passed in from main()
    # print(f"GRPC_SERVER_LOG: Using shutdown event from main, handlers already registered", flush=True)
    
    # Wait for either termination or shutdown signal
    # print("GRPC_SERVER_LOG: Starting main event loop wait", flush=True)
    server_task = asyncio.create_task(server.wait_for_termination())
    shutdown_task = asyncio.create_task(shutdown_event.wait())
    
    try:
        done, pending = await asyncio.wait(
            [server_task, shutdown_task],
            return_when=asyncio.FIRST_COMPLETED
        )
        
        # print(f"GRPC_SERVER_LOG: Event loop returned, shutdown_event.is_set()={shutdown_event.is_set()}", flush=True)
        
        # Cancel pending tasks
        for task in pending:
            task.cancel()
        
        # If shutdown was triggered, stop the server gracefully
        if shutdown_event.is_set():
            # print("GRPC_SERVER_LOG: Shutdown event triggered, stopping server...", flush=True)
            await servicer.close()
            await server.stop(grace_period=0.5)  # Quick stop for tests
            # print("GRPC_SERVER_LOG: Server stopped successfully", flush=True)
    except Exception as e:
        # print(f"GRPC_SERVER_LOG: Exception in main loop: {e}", flush=True)
        raise


async def serve(port: int, adapter_module: str, elixir_address: str):
    """Legacy entry point - creates its own shutdown event."""
    shutdown_event = asyncio.Event()
    await serve_with_shutdown(port, adapter_module, elixir_address, shutdown_event)


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
    parser.add_argument('--snakepit-run-id', type=str, default='',
                        help='Snakepit run ID for process cleanup')

    args = parser.parse_args()
    
    # Set up signal handlers at the module level before running asyncio
    shutdown_event = None
    
    def handle_signal(signum, frame):
        # print(f"GRPC_SERVER_LOG: Received signal {signum} in main process", flush=True)
        if shutdown_event and not shutdown_event.is_set():
            # Schedule the shutdown in the running loop
            asyncio.get_running_loop().call_soon_threadsafe(shutdown_event.set)
    
    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    # Create and run the server with the shutdown event
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    shutdown_event = asyncio.Event()

    try:
        loop.run_until_complete(serve_with_shutdown(args.port, args.adapter, args.elixir_address, shutdown_event))
    finally:
        loop.close()


if __name__ == '__main__':
    main()