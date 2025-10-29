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
import os
from concurrent import futures
from typing import Any, Dict, Mapping, Optional

# Add the package to Python path
sys.path.insert(0, '.')

import snakepit_bridge_pb2 as pb2
import snakepit_bridge_pb2_grpc as pb2_grpc
from snakepit_bridge.session_context import SessionContext
from snakepit_bridge.heartbeat import HeartbeatClient, HeartbeatConfig
from snakepit_bridge.serialization import TypeSerializer
from snakepit_bridge import telemetry
from snakepit_bridge.telemetry.stream import TelemetryStream
from snakepit_bridge.telemetry.backends.grpc import GrpcBackend
from google.protobuf.timestamp_pb2 import Timestamp
from google.protobuf import any_pb2
import json
import functools
import traceback
import pickle

logging.basicConfig(
    format="%(asctime)s - %(name)s - %(levelname)s - [corr=%(correlation_id)s] %(message)s",
    level=logging.INFO,
)

telemetry.setup_tracing()
_log_filter = telemetry.correlation_filter()
logger = logging.getLogger(__name__)
logger.addFilter(_log_filter)
logging.getLogger().addFilter(_log_filter)

logger.info("Loaded grpc_server.py from %s", __file__)


def _resolve_heartbeat_options(cli_options: Optional[Mapping[str, Any]]) -> Optional[Dict[str, Any]]:
    """Merge CLI-provided heartbeat overrides with Elixir-sourced env config."""

    options: Dict[str, Any] = {}

    if cli_options:
        options.update(dict(cli_options))

    raw_env = os.environ.get("SNAKEPIT_HEARTBEAT_CONFIG")

    if raw_env:
        try:
            env_options = json.loads(raw_env)
        except json.JSONDecodeError:
            logger.warning("Invalid SNAKEPIT_HEARTBEAT_CONFIG payload; ignoring.")
        else:
            if isinstance(env_options, dict):
                options.update(env_options)
            else:
                logger.warning(
                    "Expected dict for SNAKEPIT_HEARTBEAT_CONFIG, got %s", type(env_options)
                )

    return options or None


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

    def __init__(
        self,
        adapter_class,
        elixir_address: str,
        heartbeat_options: Optional[Mapping[str, Any]] = None,
        *,
        loop: Optional[asyncio.AbstractEventLoop] = None,
        shutdown_event: Optional[asyncio.Event] = None,
    ):
        logger.debug("BridgeServiceServicer.__init__ called")

        self.adapter_class = adapter_class
        self.elixir_address = elixir_address
        self.server: Optional[grpc.aio.Server] = None
        self.shutdown_event = shutdown_event

        # Initialize telemetry stream
        logger.debug("Initializing telemetry stream")
        self.telemetry_stream = TelemetryStream(max_buffer=1024)

        # Set the gRPC backend as the active telemetry backend
        telemetry.set_backend(GrpcBackend(self.telemetry_stream))
        logger.info("Telemetry backend initialized (gRPC stream)")

        logger.debug("Creating async channel to %s", elixir_address)

        # Create async client channel for async operations (proxying)
        self.elixir_channel = grpc.aio.insecure_channel(elixir_address)
        self.elixir_stub = pb2_grpc.BridgeServiceStub(self.elixir_channel)

        logger.debug("Creating sync channel to %s", elixir_address)

        # Create sync client channel for SessionContext
        self.sync_elixir_channel = grpc.insecure_channel(elixir_address)
        self.sync_elixir_stub = pb2_grpc.BridgeServiceStub(self.sync_elixir_channel)

        logger.debug("gRPC channels created successfully")
        logger.debug("grpc_server.py __file__=%s", __file__)
        logger.info(
            "ExecuteStreamingTool is coroutine? %s",
            inspect.iscoroutinefunction(self.ExecuteStreamingTool),
        )
        self.loop = loop or asyncio.get_event_loop()

        resolved_heartbeat_options = _resolve_heartbeat_options(heartbeat_options)
        self.heartbeat_config = HeartbeatConfig.from_mapping(resolved_heartbeat_options)
        self.heartbeat_clients: Dict[str, HeartbeatClient] = {}
        self._heartbeat_lock = asyncio.Lock()

        if self.heartbeat_config.enabled:
            logger.info(
                "Heartbeat client staged (interval=%sms, timeout=%sms, max_missed=%s)",
                self.heartbeat_config.interval_ms,
                self.heartbeat_config.timeout_ms,
                self.heartbeat_config.max_missed_heartbeats,
            )
        else:
            logger.debug("Heartbeat client disabled by configuration")

    async def _proxy_to_elixir(self, method_name: str, request, *, metadata=None):
        metadata = telemetry.outgoing_metadata(metadata)
        stub_method = getattr(self.elixir_stub, method_name)
        call = stub_method(request, metadata=metadata)

        if inspect.isawaitable(call):
            return await call

        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(None, lambda: call)
    
    async def close(self):
        """Clean up resources."""
        # Stop telemetry stream
        if self.telemetry_stream:
            logger.debug("Closing telemetry stream")
            self.telemetry_stream.close()

        # Stop heartbeat clients
        await self._stop_all_heartbeat_clients()

        # Close gRPC channels
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
        metadata = context.invocation_metadata()

        with telemetry.otel_span(
            "BridgeService/InitializeSession",
            context_metadata=metadata,
            attributes={"snakepit.session_id": request.session_id},
        ):
            response = await self._proxy_to_elixir("InitializeSession", request)
            await self._ensure_heartbeat_client(request.session_id)
            return response

    async def CleanupSession(self, request, context):
        """Clean up a session - proxy to Elixir."""
        logger.info(f"Proxying CleanupSession for: {request.session_id}")
        metadata = context.invocation_metadata()

        with telemetry.otel_span(
            "BridgeService/CleanupSession",
            context_metadata=metadata,
            attributes={"snakepit.session_id": request.session_id},
        ):
            try:
                response = await self._proxy_to_elixir("CleanupSession", request)
            finally:
                await self._stop_heartbeat_client(request.session_id)
            return response

    async def GetSession(self, request, context):
        """Get session details - proxy to Elixir."""
        logger.debug(f"Proxying GetSession for: {request.session_id}")
        metadata = context.invocation_metadata()

        with telemetry.otel_span(
            "BridgeService/GetSession",
            context_metadata=metadata,
            attributes={"snakepit.session_id": request.session_id},
        ):
            response = await self._proxy_to_elixir("GetSession", request)
            await self._ensure_heartbeat_client(request.session_id)
            return response

    async def Heartbeat(self, request, context):
        """Send heartbeat - proxy to Elixir."""
        logger.debug(f"Proxying Heartbeat for: {request.session_id}")
        metadata = context.invocation_metadata()

        with telemetry.otel_span(
            "BridgeService/Heartbeat",
            context_metadata=metadata,
            attributes={"snakepit.session_id": request.session_id},
        ):
            return await self._proxy_to_elixir("Heartbeat", request)
    
    # Variable Operations - All Proxied to Elixir
    
    async def RegisterVariable(self, request, context):
        """Register a variable - proxy to Elixir."""
        logger.debug(f"Proxying RegisterVariable: {request.name}")
        with telemetry.otel_span(
            "BridgeService/RegisterVariable",
            context_metadata=context.invocation_metadata(),
            attributes={"snakepit.variable": request.name},
        ):
            return await self._proxy_to_elixir("RegisterVariable", request)

    async def GetVariable(self, request, context):
        """Get a variable - proxy to Elixir."""
        logger.debug(f"Proxying GetVariable: {request.variable_identifier}")
        with telemetry.otel_span(
            "BridgeService/GetVariable",
            context_metadata=context.invocation_metadata(),
            attributes={"snakepit.variable": request.variable_identifier},
        ):
            return await self._proxy_to_elixir("GetVariable", request)

    async def SetVariable(self, request, context):
        """Set a variable - proxy to Elixir."""
        logger.debug(f"Proxying SetVariable: {request.variable_identifier}")
        with telemetry.otel_span(
            "BridgeService/SetVariable",
            context_metadata=context.invocation_metadata(),
            attributes={"snakepit.variable": request.variable_identifier},
        ):
            return await self._proxy_to_elixir("SetVariable", request)

    async def GetVariables(self, request, context):
        """Get multiple variables - proxy to Elixir."""
        logger.debug(f"Proxying GetVariables for {len(request.variable_identifiers)} variables")
        with telemetry.otel_span(
            "BridgeService/GetVariables",
            context_metadata=context.invocation_metadata(),
            attributes={"snakepit.variable_count": len(request.variable_identifiers)},
        ):
            return await self._proxy_to_elixir("GetVariables", request)

    async def SetVariables(self, request, context):
        """Set multiple variables - proxy to Elixir."""
        logger.debug(f"Proxying SetVariables for {len(request.updates)} variables")
        with telemetry.otel_span(
            "BridgeService/SetVariables",
            context_metadata=context.invocation_metadata(),
            attributes={"snakepit.variable_count": len(request.updates)},
        ):
            return await self._proxy_to_elixir("SetVariables", request)

    async def ListVariables(self, request, context):
        """List variables - proxy to Elixir."""
        logger.debug(f"Proxying ListVariables with pattern: {request.pattern}")
        with telemetry.otel_span(
            "BridgeService/ListVariables",
            context_metadata=context.invocation_metadata(),
            attributes={"snakepit.pattern": request.pattern},
        ):
            return await self._proxy_to_elixir("ListVariables", request)

    async def DeleteVariable(self, request, context):
        """Delete a variable - proxy to Elixir."""
        logger.debug(f"Proxying DeleteVariable: {request.variable_identifier}")
        with telemetry.otel_span(
            "BridgeService/DeleteVariable",
            context_metadata=context.invocation_metadata(),
            attributes={"snakepit.variable": request.variable_identifier},
        ):
            return await self._proxy_to_elixir("DeleteVariable", request)
    
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
            await self._ensure_heartbeat_client(request.session_id)
            
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
            
            # Use TypeSerializer to encode the result
            response = pb2.ExecuteToolResponse(success=True)

            # Infer the type of the result (simple type inference for now)
            if isinstance(result_data, dict):
                result_type = "map"
            elif isinstance(result_data, str):
                result_type = "string"
            elif isinstance(result_data, (int, float)):
                result_type = "float"
            elif isinstance(result_data, bool):
                result_type = "boolean"
            elif isinstance(result_data, list):
                result_type = "list"
            else:
                result_type = "string"  # Default fallback

            # Use the centralized serializer to encode the result correctly
            any_msg, binary_data = TypeSerializer.encode_any(result_data, result_type)
            
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
    
    async def ExecuteStreamingTool(self, request, context):
        """Execute a streaming tool, bridging async/sync generators safely."""
        logger.info(
            "ExecuteStreamingTool: %s for session %s", request.tool_name, request.session_id
        )

        metadata = context.invocation_metadata()

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
            await self._ensure_heartbeat_client(request.session_id)
            
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

            loop = self.loop
            queue: asyncio.Queue = asyncio.Queue()
            sentinel = object()
            chunk_id_counter = 0
            marked_final = False

            def encode_payload(payload):
                if payload is None:
                    return b""
                if isinstance(payload, (bytes, bytearray, memoryview)):
                    return bytes(payload)
                if isinstance(payload, str):
                    return payload.encode("utf-8")
                return json.dumps(payload).encode("utf-8")

            def build_chunk(payload, *, is_final=False, metadata=None):
                nonlocal chunk_id_counter, marked_final
                chunk_id_counter += 1
                chunk = pb2.ToolChunk(
                    chunk_id=f"{request.tool_name}-{chunk_id_counter}",
                    data=encode_payload(payload),
                    is_final=is_final,
                )

                if metadata and isinstance(metadata, dict):
                    chunk.metadata.update({str(k): str(v) for k, v in metadata.items()})

                if is_final:
                    marked_final = True

                return chunk

            async def enqueue_chunk(payload, *, is_final=False, metadata=None):
                await queue.put(build_chunk(payload, is_final=is_final, metadata=metadata))

            def unpack_chunk(chunk_data):
                payload = chunk_data
                metadata = None
                is_final = False

                if hasattr(chunk_data, "data"):
                    payload = getattr(chunk_data, "data")

                if hasattr(chunk_data, "is_final"):
                    is_final = bool(getattr(chunk_data, "is_final"))

                if hasattr(chunk_data, "metadata"):
                    meta_attr = getattr(chunk_data, "metadata")
                    if isinstance(meta_attr, dict):
                        metadata = meta_attr

                return payload, is_final, metadata

            async def drain_async(iterator):
                async for chunk_data in iterator:
                    payload, is_final, metadata = unpack_chunk(chunk_data)
                    await enqueue_chunk(payload, is_final=is_final, metadata=metadata)

            def drain_sync(iterator):
                for chunk_data in iterator:
                    payload, is_final, metadata = unpack_chunk(chunk_data)
                    fut = asyncio.run_coroutine_threadsafe(
                        enqueue_chunk(payload, is_final=is_final, metadata=metadata),
                        loop,
                    )
                    fut.result()

            async def produce_chunks():
                error_raised = False
                try:
                    if hasattr(stream_iterator, "__aiter__"):
                        await drain_async(stream_iterator)
                    elif hasattr(stream_iterator, "__iter__"):
                        await asyncio.to_thread(drain_sync, stream_iterator)
                    else:
                        payload, is_final, metadata = unpack_chunk(stream_iterator)
                        await enqueue_chunk(payload, is_final=is_final, metadata=metadata)
                except Exception as iteration_error:
                    error_raised = True
                    await queue.put(iteration_error)
                finally:
                    if not error_raised and not marked_final:
                        await enqueue_chunk(None, is_final=True)
                    await queue.put(sentinel)

            asyncio.create_task(produce_chunks())

            while True:
                item = await queue.get()
                if item is sentinel:
                    break
                if isinstance(item, Exception):
                    logger.error(
                        "Streaming tool %s raised %s",
                        request.tool_name,
                        item,
                        exc_info=True,
                    )
                    await context.abort(grpc.StatusCode.INTERNAL, str(item))
                    return
                yield item

        except Exception as e:
            logger.error(f"ExecuteStreamingTool failed: {e}", exc_info=True)
            await context.abort(grpc.StatusCode.INTERNAL, str(e))

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
        with telemetry.otel_span(
            "BridgeService/AddDependency",
            context_metadata=context.invocation_metadata(),
        ):
            return await self._proxy_to_elixir("AddDependency", request)

    async def StartOptimization(self, request, context):
        """Start optimization - proxy to Elixir when implemented."""
        logger.debug("Proxying StartOptimization")
        with telemetry.otel_span(
            "BridgeService/StartOptimization",
            context_metadata=context.invocation_metadata(),
        ):
            return await self._proxy_to_elixir("StartOptimization", request)

    async def StopOptimization(self, request, context):
        """Stop optimization - proxy to Elixir when implemented."""
        logger.debug("Proxying StopOptimization")
        with telemetry.otel_span(
            "BridgeService/StopOptimization",
            context_metadata=context.invocation_metadata(),
        ):
            return await self._proxy_to_elixir("StopOptimization", request)

    async def GetVariableHistory(self, request, context):
        """Get variable history - proxy to Elixir when implemented."""
        logger.debug("Proxying GetVariableHistory")
        with telemetry.otel_span(
            "BridgeService/GetVariableHistory",
            context_metadata=context.invocation_metadata(),
        ):
            return await self._proxy_to_elixir("GetVariableHistory", request)

    async def RollbackVariable(self, request, context):
        """Rollback variable - proxy to Elixir when implemented."""
        logger.debug("Proxying RollbackVariable")
        with telemetry.otel_span(
            "BridgeService/RollbackVariable",
            context_metadata=context.invocation_metadata(),
        ):
            return await self._proxy_to_elixir("RollbackVariable", request)

    # Telemetry Stream

    async def StreamTelemetry(self, request_iterator, context):
        """
        Bidirectional telemetry stream handler.

        Receives control messages from Elixir (sampling, filtering, toggle)
        and yields telemetry events from Python back to Elixir.
        """
        logger.debug("StreamTelemetry stream opened")

        try:
            # Delegate to the TelemetryStream's stream handler
            # This handles control message consumption and event yielding
            async for event in self.telemetry_stream.stream(request_iterator, context):
                yield event

            logger.debug("StreamTelemetry stream completed normally")

        except Exception as e:
            logger.error("StreamTelemetry stream error: %s", e, exc_info=True)
            raise

    def set_server(self, server):
        """Set the server reference for graceful shutdown."""
        self.server = server

    def create_heartbeat_client(self, session_id: str) -> Optional[HeartbeatClient]:
        """
        Prepare a heartbeat client for the given session.

        The caller is responsible for starting/stopping the client; this helper
        simply encapsulates configuration so future integration work can toggle
        the feature without refactoring the servicer.
        """
        if not self.heartbeat_config.enabled:
            return None

        threshold_handler = None

        if self.heartbeat_config.dependent:
            threshold_handler = self._build_dependent_threshold_handler(session_id)

        return HeartbeatClient(
            self.elixir_stub,
            session_id,
            config=self.heartbeat_config,
            on_threshold_exceeded=threshold_handler,
        )

    def _build_dependent_threshold_handler(self, session_id: str):
        async def _handler(missed: int) -> None:
            logger.error(
                "Heartbeat threshold exceeded for session %s (missed=%s); shutting down.",
                session_id,
                missed,
            )

            if self.shutdown_event and not self.shutdown_event.is_set():
                self.shutdown_event.set()

            loop = asyncio.get_running_loop()
            loop.call_soon(os.kill, os.getpid(), signal.SIGTERM)

        return _handler

    async def _ensure_heartbeat_client(self, session_id: str) -> Optional[HeartbeatClient]:
        """
        Initialise and start a heartbeat client for the session if enabled.
        """
        if not self.heartbeat_config.enabled:
            return None

        client = self.heartbeat_clients.get(session_id)
        if client:
            return client

        async with self._heartbeat_lock:
            client = self.heartbeat_clients.get(session_id)
            if client:
                return client

            client = self.create_heartbeat_client(session_id)
            if client:
                started = client.start()
                if started:
                    logger.debug("Heartbeat loop started for session %s", session_id)
                self.heartbeat_clients[session_id] = client
            return client

    async def _stop_heartbeat_client(self, session_id: str) -> None:
        """
        Stop and remove the heartbeat client for the given session.
        """
        if not self.heartbeat_config.enabled:
            return

        async with self._heartbeat_lock:
            client = self.heartbeat_clients.pop(session_id, None)

        if client:
            await client.stop()
            logger.debug("Heartbeat loop stopped for session %s", session_id)

    async def _stop_all_heartbeat_clients(self) -> None:
        if not self.heartbeat_clients:
            return

        async with self._heartbeat_lock:
            clients = list(self.heartbeat_clients.values())
            self.heartbeat_clients.clear()

        for client in clients:
            await client.stop()


async def wait_for_elixir_server(
    elixir_address: str,
    max_retries: Optional[int] = 60,
    initial_delay: float = 0.05,
):
    """
    Wait for the Elixir gRPC server to become available with exponential backoff.

    This handles the startup race condition where Python workers may spawn before
    the Elixir gRPC Bridge Server has fully bound to its socket.

    Args:
        elixir_address: The address of the Elixir server (e.g., 'localhost:50051')
        max_retries: Maximum number of connection attempts
        initial_delay: Initial delay in seconds (doubles each retry)

    Returns:
        True if server is reachable, False otherwise
    """
    delay = initial_delay
    attempt = 1

    while True:
        try:
            # Attempt a simple connection test
            channel = grpc.aio.insecure_channel(elixir_address)
            stub = pb2_grpc.BridgeServiceStub(channel)

            # Try a ping with short timeout
            request = pb2.PingRequest(message="connection_test")
            await asyncio.wait_for(stub.Ping(request), timeout=1.0)

            # Success!
            await channel.close()
            logger.info(
                "Successfully connected to Elixir server at %s after %d attempt(s)",
                elixir_address,
                attempt,
            )
            return True

        except (grpc.aio.AioRpcError, asyncio.TimeoutError, Exception) as e:
            if max_retries is not None and attempt >= max_retries:
                logger.error(
                    "Failed to connect to Elixir server at %s after %d attempts (last error: %s: %s)",
                    elixir_address,
                    attempt,
                    type(e).__name__,
                    e,
                )
                return False

            total_suffix = f"/{max_retries}" if max_retries is not None else ""
            logger.debug(
                "Elixir server at %s not ready (attempt %d%s). Retrying in %.2fs... Error: %s: %s",
                elixir_address,
                attempt,
                total_suffix,
                delay,
                type(e).__name__,
                e,
            )
            logger.debug(
                "wait_for_elixir_server attempt %d failed: %s: %s",
                attempt,
                type(e).__name__,
                e,
            )

            await asyncio.sleep(delay)
            delay = min(delay * 2, 2.0)  # Exponential backoff, max 2s
            attempt += 1


async def serve_with_shutdown(
    port: int,
    adapter_module: str,
    elixir_address: str,
    shutdown_event: asyncio.Event,
    heartbeat_options: Optional[Mapping[str, Any]] = None,
):
    """Start the stateless gRPC server with proper shutdown handling."""
    logger.debug(
        "serve_with_shutdown called (port=%s, adapter=%s, elixir_address=%s)",
        port,
        adapter_module,
        elixir_address,
    )

    # CRITICAL: Wait for Elixir server to be ready before proceeding
    # This prevents the Python worker from exiting if the Elixir server is still starting up
    logger.debug("Waiting for Elixir server before starting worker")

    result = await wait_for_elixir_server(elixir_address)

    logger.debug("wait_for_elixir_server returned %s", result)

    if not result:
        logger.error(f"Cannot start Python worker: Elixir server at {elixir_address} is not available")
        sys.exit(1)

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
    logger.debug("Creating gRPC server")

    server = grpc.aio.server(
        futures.ThreadPoolExecutor(max_workers=10),
        options=[
            ('grpc.max_send_message_length', 100 * 1024 * 1024),  # 100MB
            ('grpc.max_receive_message_length', 100 * 1024 * 1024),
        ]
    )

    logger.debug("Creating bridge servicer")

    loop = asyncio.get_running_loop()

    servicer = BridgeServiceServicer(
        adapter_class,
        elixir_address,
        heartbeat_options=heartbeat_options,
        loop=loop,
        shutdown_event=shutdown_event,
    )
    servicer.set_server(server)

    pb2_grpc.add_BridgeServiceServicer_to_server(servicer, server)

    # Listen on port
    logger.debug("Binding to port %s", port)

    try:
        actual_port = server.add_insecure_port(f'[::]:{port}')

        logger.debug("Bound to port %s", actual_port)

        if actual_port == 0 and port != 0:
            error_msg = f"Failed to bind to port {port} - port may already be in use"
            logger.error(error_msg)
            sys.exit(1)
    except Exception as e:
        error_msg = f"Exception binding to port {port}: {type(e).__name__}: {e}"
        logger.exception(error_msg)
        sys.exit(1)

    logger.debug("Starting gRPC server")

    await server.start()

    logger.debug("Server started; announcing readiness on port %s", actual_port)

    # Signal that the server is ready
    # CRITICAL: Use logger instead of print() for reliable capture via :stderr_to_stdout
    logger.info(f"GRPC_READY:{actual_port}")

    logger.info(f"gRPC server started on port {actual_port}")
    logger.info(f"Connected to Elixir backend at {elixir_address}")

    logger.debug("Entering main event loop")

    # CRITICAL: A true daemon waits ONLY for the shutdown signal.
    # Do not wait for server termination - that would cause premature exit.
    server_task = asyncio.create_task(server.wait_for_termination())

    try:
        logger.debug("Awaiting shutdown signal (SIGTERM/SIGINT)")

        # Wait indefinitely until a shutdown signal is received
        # This makes the worker a true daemon that will not exit on its own
        await shutdown_event.wait()

        logger.debug("Shutdown signal received; initiating graceful shutdown")

    finally:
        # This block executes regardless of how we exited the try block
        # Clean up the server_task
        server_task.cancel()

        logger.debug("Closing servicer and stopping server")

        try:
            await servicer.close()
            # CRITICAL FIX: grpcio 1.75+ changed API - grace period is positional, not keyword
            await server.stop(0.5)

            logger.debug("Server stopped gracefully")
        except asyncio.CancelledError:
            # CRITICAL FIX: This is expected if the parent Elixir process closes the port
            # while we are in the middle of a graceful shutdown.
            # We can safely ignore it and allow the process to exit.
            logger.info("Shutdown cancelled by parent (this is normal).")

        logger.debug("serve_with_shutdown completed")


async def serve(port: int, adapter_module: str, elixir_address: str):
    """Legacy entry point - creates its own shutdown event."""
    shutdown_event = asyncio.Event()
    await serve_with_shutdown(
        port,
        adapter_module,
        elixir_address,
        shutdown_event,
        heartbeat_options=None,
    )


async def shutdown(server):
    """Gracefully shutdown the server."""
    # CRITICAL FIX: grpcio 1.75+ changed API - grace period is positional, not keyword
    await server.stop(5)


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
    parser.add_argument('--heartbeat-enabled', action='store_true',
                        help='Enable Python heartbeat client')
    parser.add_argument('--heartbeat-interval-ms', type=int, default=None,
                        help='Heartbeat interval in milliseconds')
    parser.add_argument('--heartbeat-timeout-ms', type=int, default=None,
                        help='Heartbeat RPC timeout in milliseconds')
    parser.add_argument('--heartbeat-max-missed', type=int, default=None,
                        help='Maximum consecutive heartbeat failures before escalation')
    parser.add_argument('--heartbeat-initial-delay-ms', type=int, default=None,
                        help='Initial delay before starting heartbeat loop (milliseconds)')
    parser.add_argument(
        '--heartbeat-dependent',
        dest='heartbeat_dependent',
        action='store_true',
        help='Exit when Elixir heartbeat is lost (default behaviour)'
    )
    parser.add_argument(
        '--heartbeat-independent',
        dest='heartbeat_dependent',
        action='store_false',
        help='Keep running even when Elixir heartbeat is lost'
    )
    parser.set_defaults(heartbeat_dependent=None)

    args = parser.parse_args()

    heartbeat_overrides: Dict[str, Any] = {}

    if args.heartbeat_enabled:
        heartbeat_overrides["enabled"] = True

    if args.heartbeat_interval_ms is not None:
        heartbeat_overrides["interval_ms"] = args.heartbeat_interval_ms

    if args.heartbeat_timeout_ms is not None:
        heartbeat_overrides["timeout_ms"] = args.heartbeat_timeout_ms

    if args.heartbeat_max_missed is not None:
        heartbeat_overrides["max_missed_heartbeats"] = args.heartbeat_max_missed

    if args.heartbeat_initial_delay_ms is not None:
        heartbeat_overrides["initial_delay_ms"] = args.heartbeat_initial_delay_ms

    if args.heartbeat_dependent is not None:
        heartbeat_overrides["dependent"] = args.heartbeat_dependent

    heartbeat_options = heartbeat_overrides or None

    # Set up signal handlers at the module level before running asyncio
    shutdown_event = None

    def handle_signal(signum, frame):
        logger.warning(
            "Signal %s (%s) received; initiating shutdown",
            signum,
            signal.Signals(signum).name,
        )
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
        loop.run_until_complete(
            serve_with_shutdown(
                args.port,
                args.adapter,
                args.elixir_address,
                shutdown_event,
                heartbeat_options=heartbeat_options,
            )
        )
    except BaseException as e:
        # CRITICAL: Capture the final, fatal exception before the process dies
        # Catch ALL exceptions including SystemExit, KeyboardInterrupt, etc.
        logger.exception("Unhandled exception in main loop: %s", e)
        # Re-exit with error code so OS knows it failed
        sys.exit(1)
    finally:
        loop.close()

    # Main loop exited after shutdown event; this is expected during graceful termination.
    logger.info("Python worker exiting gracefully.")


if __name__ == '__main__':
    main()
