#!/usr/bin/env python3
"""
Stateless gRPC bridge server for DSPex.

This server acts as a proxy for state operations (forwarding to Elixir)
and as an execution environment for Python tools.
"""

import json
import functools
import traceback
import pickle
import argparse
import asyncio
import inspect
import importlib
import logging
import os
import signal
import sys
import time
from concurrent import futures
from typing import Any, Dict, Mapping, Optional

from snakepit_bridge.logging_config import configure_logging, get_logger

if __name__ == "__main__":
    configure_logging()

# Add the package to Python path
sys.path.insert(0, '.')

import grpc
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

def maybe_create_process_group():
    enabled = os.environ.get("SNAKEPIT_PROCESS_GROUP", "").lower() in ("1", "true", "yes", "on")
    if not enabled:
        return False

    if os.name != "posix" or not hasattr(os, "setsid"):
        return False

    try:
        os.setsid()
        logger.debug("Snakepit process group created")
        return True
    except Exception as exc:
        logger.warning("Failed to create process group: %s", exc)
        return False

telemetry.setup_tracing()
_log_filter = telemetry.correlation_filter()
logger = get_logger("grpc_server")
logger.addFilter(_log_filter)
logging.getLogger().addFilter(_log_filter)


def run_health_check(adapter_path: str):
    """Basic dependency check for Mix doctor."""
    try:
        module_name, _, class_name = adapter_path.rpartition(".")
        adapter_module = importlib.import_module(module_name)
        getattr(adapter_module, class_name)
    except Exception as exc:
        logger.error("Health check failed to import adapter '%s': %s", adapter_path, exc)
        sys.exit(1)

    logger.info("Health check passed: Python gRPC dependencies loaded successfully.")
    sys.exit(0)


def _signal_ready(actual_port: int) -> None:
    ready_file = os.environ.get("SNAKEPIT_READY_FILE")
    if not ready_file:
        logger.debug("SNAKEPIT_READY_FILE not set; readiness signal skipped.")
        return

    try:
        tmp_path = f"{ready_file}.tmp"
        with open(tmp_path, "w", encoding="utf-8") as handle:
            handle.write(str(actual_port))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_path, ready_file)
        logger.debug("Readiness file written: %s", ready_file)
    except Exception as exc:
        logger.error("Failed to write readiness file %s: %s", ready_file, exc)
        raise


def _extract_callsite_context(arguments: Optional[Dict[str, Any]], request) -> Dict[str, Any]:
    context: Dict[str, Any] = {
        "tool_name": getattr(request, "tool_name", None),
        "session_id": getattr(request, "session_id", None),
    }

    if isinstance(arguments, dict):
        for key in ("library", "python_module", "function", "call_type", "payload_version"):
            if key in arguments:
                context[key] = arguments[key]

    return {k: v for k, v in context.items() if v is not None}


def _build_error_payload(exc: Exception, request, arguments: Optional[Dict[str, Any]] = None):
    exc_type = type(exc).__name__
    message = str(exc)
    stacktrace = traceback.format_exception(type(exc), exc, exc.__traceback__)

    return {
        "type": exc_type,
        "message": message,
        "stacktrace": stacktrace,
        "traceback": "".join(stacktrace),
        "context": _extract_callsite_context(arguments, request),
    }


def _truthy_metadata(value: Optional[str]) -> bool:
    if value is None:
        return False
    return str(value).strip().lower() in ("1", "true", "t", "yes", "y", "on")


def _thread_sensitive_from_metadata(request) -> bool:
    try:
        metadata = getattr(request, "metadata", None)
        if metadata and _truthy_metadata(metadata.get("thread_sensitive")):
            return True
    except Exception:
        pass
    return False


def _thread_sensitive_from_env(arguments: Optional[Dict[str, Any]]) -> bool:
    if not arguments:
        return False

    raw = os.environ.get("SNAKEPIT_THREAD_SENSITIVE", "")
    if not raw:
        return False

    entries = {item.strip() for item in raw.split(",") if item.strip()}
    if not entries:
        return False

    module = (
        arguments.get("module_path")
        or arguments.get("python_module")
        or arguments.get("library")
    )
    function = arguments.get("function") or arguments.get("method")

    if module and module in entries:
        return True
    if module and function and f"{module}.{function}" in entries:
        return True
    return False


async def _call_maybe_async(func, *args, **kwargs):
    """
    Call a function that may be sync or async without blocking the event loop.

    Sync functions are executed in a worker thread to keep the gRPC event loop
    responsive (critical for long-running model initialization).
    """
    thread_sensitive = kwargs.pop("_thread_sensitive", False)

    if inspect.iscoroutinefunction(func):
        return await func(*args, **kwargs), "async"

    if thread_sensitive:
        result = func(*args, **kwargs)
    else:
        result = await asyncio.to_thread(func, *args, **kwargs)

    if inspect.isawaitable(result):
        return await result, "awaitable"

    return result, "thread"


async def _maybe_cleanup(adapter) -> None:
    """
    Call adapter.cleanup() if it exists, handling both sync and async implementations.

    Uses isawaitable() instead of iscoroutinefunction() to correctly handle
    wrapped/partial/decorated async functions.
    """
    if not hasattr(adapter, 'cleanup'):
        return
    try:
        result = adapter.cleanup()
        if inspect.isawaitable(result):
            await result
    except Exception as cleanup_error:
        logger.warning("Adapter cleanup failed: %s", cleanup_error)


async def _close_iterator(iterator) -> None:
    """
    Properly close an iterator/generator to release resources.

    Handles both sync and async generators.
    """
    if iterator is None:
        return
    try:
        if hasattr(iterator, 'aclose'):
            await iterator.aclose()
        elif hasattr(iterator, 'close'):
            iterator.close()
    except Exception as close_error:
        logger.debug("Iterator close failed (usually benign): %s", close_error)


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

        self._registered_sessions = set()
        self._register_lock = asyncio.Lock()

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
    
    # Tool Execution - Stateless with Ephemeral Context
    
    @grpc_error_handler
    async def ExecuteTool(self, request, context):
        """Executes a non-streaming tool."""
        logger.info(f"ExecuteTool: {request.tool_name} for session {request.session_id}")
        start_time = time.time()
        metadata = context.invocation_metadata()
        adapter = None
        thread_sensitive = _thread_sensitive_from_metadata(request)

        with telemetry.otel_span(
            "BridgeService/ExecuteTool",
            context_metadata=metadata,
            attributes={
                "snakepit.session_id": request.session_id,
                "snakepit.tool": request.tool_name,
            },
        ):
            try:
                if hasattr(context, "time_remaining"):
                    remaining = context.time_remaining()
                    if remaining is not None:
                        logger.debug(
                            "ExecuteTool deadline remaining: %.2fs (tool=%s, session=%s)",
                            remaining,
                            request.tool_name,
                            request.session_id,
                        )

                # Ensure session exists in Elixir
                init_request = pb2.InitializeSessionRequest(session_id=request.session_id)
                try:
                    self.sync_elixir_stub.InitializeSession(init_request)
                except grpc.RpcError as e:
                    # Session might already exist, that's ok
                    if e.code() != grpc.StatusCode.ALREADY_EXISTS:
                        logger.debug(f"InitializeSession for {request.session_id}: {e}")

                # Create ephemeral context for this request
                session_context = SessionContext(
                    self.sync_elixir_stub,
                    request.session_id,
                    request_metadata=dict(request.metadata),
                )
                await self._ensure_heartbeat_client(request.session_id)

                # Create adapter instance for this request
                adapter = self.adapter_class()
                adapter.set_session_context(session_context)

                # Register adapter tools with the session (for new BaseAdapter)
                if hasattr(adapter, 'register_with_session'):
                    await self._ensure_tools_registered(request.session_id, adapter)

                # Initialize adapter if needed (uses isawaitable for robustness)
                if hasattr(adapter, 'initialize'):
                    init_start = time.monotonic()
                    _init_result, init_mode = await _call_maybe_async(
                        adapter.initialize,
                        _thread_sensitive=thread_sensitive,
                    )
                    init_duration = time.monotonic() - init_start
                    logger.debug(
                        "Adapter initialize completed in %.2fs (mode=%s, tool=%s)",
                        init_duration,
                        init_mode,
                        request.tool_name,
                    )

                # Decode parameters from protobuf Any using TypeSerializer
                arguments = {key: TypeSerializer.decode_any(any_msg) for key, any_msg in request.parameters.items()}
                # Handle binary parameters - raw bytes by default, pickle only if metadata specifies
                for key, binary_val in request.binary_parameters.items():
                    format_key = f"binary_format:{key}"
                    if request.metadata.get(format_key) == "pickle":
                        arguments[key] = pickle.loads(binary_val)
                    else:
                        # Treat as opaque bytes (images, audio, etc.)
                        arguments[key] = binary_val

                if not thread_sensitive:
                    thread_sensitive = _thread_sensitive_from_env(arguments)

                # Execute the tool
                if not hasattr(adapter, 'execute_tool'):
                    raise grpc.RpcError(grpc.StatusCode.UNIMPLEMENTED, "Adapter does not support 'execute_tool'")

                # Execute - handle both sync and async
                exec_start = time.monotonic()
                result_data, exec_mode = await _call_maybe_async(
                    adapter.execute_tool,
                    tool_name=request.tool_name,
                    arguments=arguments,
                    context=session_context,
                    _thread_sensitive=thread_sensitive,
                )
                exec_duration = time.monotonic() - exec_start
                logger.debug(
                    "Adapter execute_tool completed in %.2fs (mode=%s, tool=%s)",
                    exec_duration,
                    exec_mode,
                    request.tool_name,
                )

                # Check if a generator was mistakenly returned (should have been called via streaming endpoint)
                if inspect.isgenerator(result_data) or inspect.isasyncgen(result_data):
                    logger.warning(f"Tool '{request.tool_name}' returned a generator but was called via non-streaming ExecuteTool. Returning empty result.")
                    result_data = {"error": "Streaming tool called on non-streaming endpoint."}

                # Use TypeSerializer to encode the result
                response = pb2.ExecuteToolResponse(success=True)

                # Infer the type of the result (simple type inference for now)
                # IMPORTANT: Check bool BEFORE int/float because bool is a subclass of int.
                # isinstance(True, (int, float)) returns True, so we must check bool first.
                if isinstance(result_data, bool):
                    result_type = "boolean"
                elif isinstance(result_data, dict):
                    result_type = "map"
                elif isinstance(result_data, str):
                    result_type = "string"
                elif isinstance(result_data, (int, float)):
                    result_type = "float"
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
                payload = _build_error_payload(e, request, locals().get("arguments"))
                response.error_message = json.dumps(payload)
                return response

            finally:
                # Always cleanup adapter
                if adapter is not None:
                    await _maybe_cleanup(adapter)
    
    async def ExecuteStreamingTool(self, request, context):
        """Execute a streaming tool, bridging async/sync generators safely."""
        logger.info(
            "ExecuteStreamingTool: %s for session %s", request.tool_name, request.session_id
        )

        metadata = context.invocation_metadata()
        adapter = None
        stream_iterator = None
        thread_sensitive = _thread_sensitive_from_metadata(request)

        with telemetry.otel_span(
            "BridgeService/ExecuteStreamingTool",
            context_metadata=metadata,
            attributes={
                "snakepit.session_id": request.session_id,
                "snakepit.tool": request.tool_name,
            },
        ):
            try:
                if hasattr(context, "time_remaining"):
                    remaining = context.time_remaining()
                    if remaining is not None:
                        logger.debug(
                            "ExecuteStreamingTool deadline remaining: %.2fs (tool=%s, session=%s)",
                            remaining,
                            request.tool_name,
                            request.session_id,
                        )

                # Ensure session exists in Elixir
                init_request = pb2.InitializeSessionRequest(session_id=request.session_id)
                try:
                    self.sync_elixir_stub.InitializeSession(init_request)
                except grpc.RpcError as e:
                    # Session might already exist, that's ok
                    if e.code() != grpc.StatusCode.ALREADY_EXISTS:
                        logger.debug(f"InitializeSession for {request.session_id}: {e}")

                # Create ephemeral context for this request
                logger.debug(f"Creating SessionContext for {request.session_id}")
                session_context = SessionContext(
                    self.sync_elixir_stub,
                    request.session_id,
                    request_metadata=dict(request.metadata),
                )
                await self._ensure_heartbeat_client(request.session_id)

                # Create adapter instance for this request
                logger.debug(f"Creating adapter instance: {self.adapter_class}")
                adapter = self.adapter_class()
                adapter.set_session_context(session_context)

                # Register adapter tools with the session (for new BaseAdapter)
                if hasattr(adapter, 'register_with_session'):
                    await self._ensure_tools_registered(request.session_id, adapter)

                # Initialize adapter (uses isawaitable for robustness)
                if hasattr(adapter, 'initialize'):
                    init_start = time.monotonic()
                    _init_result, init_mode = await _call_maybe_async(
                        adapter.initialize,
                        _thread_sensitive=thread_sensitive,
                    )
                    init_duration = time.monotonic() - init_start
                    logger.debug(
                        "Adapter initialize completed in %.2fs (mode=%s, tool=%s)",
                        init_duration,
                        init_mode,
                        request.tool_name,
                    )

                # Decode parameters from protobuf Any using TypeSerializer
                arguments = {key: TypeSerializer.decode_any(any_msg) for key, any_msg in request.parameters.items()}
                # Handle binary parameters - raw bytes by default, pickle only if metadata specifies
                for key, binary_val in request.binary_parameters.items():
                    format_key = f"binary_format:{key}"
                    if request.metadata.get(format_key) == "pickle":
                        arguments[key] = pickle.loads(binary_val)
                    else:
                        # Treat as opaque bytes (images, audio, etc.)
                        arguments[key] = binary_val

                if not thread_sensitive:
                    thread_sensitive = _thread_sensitive_from_env(arguments)

                # Execute the tool
                if not hasattr(adapter, 'execute_tool'):
                    await context.abort(grpc.StatusCode.UNIMPLEMENTED, "Adapter does not support tool execution")
                    return

                # Execute - handle both sync and async
                exec_start = time.monotonic()
                stream_iterator, exec_mode = await _call_maybe_async(
                    adapter.execute_tool,
                    tool_name=request.tool_name,
                    arguments=arguments,
                    context=session_context,
                    _thread_sensitive=thread_sensitive,
                )
                exec_duration = time.monotonic() - exec_start
                logger.debug(
                    "Adapter execute_tool completed in %.2fs (mode=%s, tool=%s)",
                    exec_duration,
                    exec_mode,
                    request.tool_name,
                )

                loop = self.loop
                # Bounded queue prevents unbounded memory growth if consumer is slow
                queue: asyncio.Queue = asyncio.Queue(maxsize=100)
                sentinel = object()
                cancelled = asyncio.Event()
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
                        if cancelled.is_set():
                            # Client disconnected; stop producing
                            break
                        payload, is_final, metadata = unpack_chunk(chunk_data)
                        await enqueue_chunk(payload, is_final=is_final, metadata=metadata)

                def drain_sync(iterator):
                    for chunk_data in iterator:
                        if cancelled.is_set():
                            # Client disconnected; stop producing
                            break
                        payload, is_final, metadata = unpack_chunk(chunk_data)
                        fut = asyncio.run_coroutine_threadsafe(
                            enqueue_chunk(payload, is_final=is_final, metadata=metadata),
                            loop,
                        )
                        # Block on enqueue to apply backpressure (bounded queue)
                        try:
                            fut.result()
                        except Exception:
                            # Queue full or cancelled - stop producing
                            cancelled.set()
                            break

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
                    except asyncio.CancelledError:
                        # Producer was cancelled - this is expected on client disconnect
                        # Must re-raise to properly terminate the task (no sentinel needed)
                        logger.debug("Streaming producer cancelled")
                        raise
                    except Exception as iteration_error:
                        error_raised = True
                        await queue.put(iteration_error)
                        # Sentinel must be delivered so consumer can terminate
                        await queue.put(sentinel)
                    else:
                        # Normal completion - deliver final chunk and sentinel
                        if not marked_final and not cancelled.is_set():
                            await enqueue_chunk(None, is_final=True)
                        # Sentinel MUST be delivered so consumer terminates (await guarantees this)
                        if not cancelled.is_set():
                            await queue.put(sentinel)

                async def watch_disconnect():
                    """Watch for client disconnect and signal cancellation."""
                    while not cancelled.is_set():
                        # Check if context is still active
                        if hasattr(context, 'is_active') and not context.is_active():
                            logger.debug("Client disconnected (context inactive)")
                            cancelled.set()

                            # Ensure consumer unblocks: guarantee sentinel insertion.
                            # This is critical because producer may exit normally (not via
                            # CancelledError) and skip sentinel delivery when cancelled is set.
                            try:
                                queue.put_nowait(sentinel)
                            except asyncio.QueueFull:
                                # Drop buffered chunks until sentinel fits
                                while True:
                                    try:
                                        _ = queue.get_nowait()
                                    except asyncio.QueueEmpty:
                                        break
                                    try:
                                        queue.put_nowait(sentinel)
                                        break
                                    except asyncio.QueueFull:
                                        continue
                            break
                        await asyncio.sleep(0.1)

                producer_task = asyncio.create_task(produce_chunks())
                watcher_task = asyncio.create_task(watch_disconnect())

                try:
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
                            payload = _build_error_payload(item, request, locals().get("arguments"))
                            cancelled.set()  # Signal producer to stop
                            await context.abort(grpc.StatusCode.INTERNAL, json.dumps(payload))
                            return
                        yield item
                finally:
                    # Ensure producer stops if client disconnects or we exit early
                    cancelled.set()
                    watcher_task.cancel()
                    producer_task.cancel()
                    # Suppress cancellation exceptions from tasks
                    try:
                        await watcher_task
                    except asyncio.CancelledError:
                        pass
                    try:
                        await producer_task
                    except asyncio.CancelledError:
                        pass
                    # Close the iterator to release resources
                    await _close_iterator(stream_iterator)
                    # Cleanup adapter
                    await _maybe_cleanup(adapter)

            except Exception as e:
                logger.error(f"ExecuteStreamingTool failed: {e}", exc_info=True)
                # Cleanup on early failure
                await _close_iterator(stream_iterator)
                await _maybe_cleanup(adapter)
                payload = _build_error_payload(e, request, locals().get("arguments"))
                await context.abort(grpc.StatusCode.INTERNAL, json.dumps(payload))

    async def _ensure_tools_registered(self, session_id: str, adapter) -> None:
        if session_id in self._registered_sessions:
            return

        async with self._register_lock:
            if session_id in self._registered_sessions:
                return

            registered_tools = adapter.register_with_session(session_id, self.sync_elixir_stub)
            if registered_tools is not None:
                self._registered_sessions.add(session_id)

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
        elixir_address: The address of the Elixir server (e.g., '127.0.0.1:50051')
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

    logger.debug("Server started; writing readiness file for port %s", actual_port)
    _signal_ready(actual_port)

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
        logger.debug("Closing servicer and stopping server")

        try:
            # 1. Close servicer first - this stops heartbeat clients and
            #    sends sentinel to telemetry stream to unblock StreamTelemetry RPC
            await servicer.close()

            # 2. Stop the server with a reasonable grace period (2 seconds)
            #    This allows in-flight RPCs to complete before force-closing
            #    CRITICAL FIX: grpcio 1.75+ changed API - grace period is positional
            await server.stop(2.0)

            # 3. Await server termination task to complete naturally (event-driven).
            #    Only cancel if it doesn't complete in time (timeout as safety net).
            #    This lets wait_for_termination() do its draining work properly.
            try:
                await asyncio.wait_for(server_task, timeout=3.0)
                logger.debug("Server termination task completed naturally")
            except asyncio.TimeoutError:
                logger.warning("Server termination timed out, cancelling task")
                server_task.cancel()
                try:
                    await server_task
                except asyncio.CancelledError:
                    pass

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
    configure_logging()
    logger.debug("Loaded grpc_server.py from %s", __file__)

    parser = argparse.ArgumentParser(description='DSPex gRPC Bridge Server')
    parser.add_argument('--port', type=int, default=0,
                        help='Port to listen on (0 for dynamic allocation)')
    parser.add_argument('--adapter', type=str, required=False,
                        help='Python module path to adapter class')
    default_elixir_address = os.environ.get("SNAKEPIT_GRPC_ADDRESS") or os.environ.get(
        "SNAKEPIT_ELIXIR_ADDRESS"
    )
    parser.add_argument(
        '--elixir-address',
        type=str,
        required=False,
        default=default_elixir_address,
        help='Address of the Elixir gRPC server (e.g., 127.0.0.1:50051 or SNAKEPIT_GRPC_ADDRESS)',
    )
    parser.add_argument('--snakepit-run-id', type=str, default='',
                        help='Snakepit run ID for process cleanup')
    parser.add_argument('--snakepit-instance-name', type=str, default='',
                        help='Snakepit instance name for process scoping')
    parser.add_argument('--snakepit-instance-token', type=str, default='',
                        help='Snakepit instance token for process scoping')
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
    parser.add_argument(
        '--health-check',
        action='store_true',
        help='Verify dependencies and exit without starting the server'
    )

    args = parser.parse_args()

    if args.health_check:
        adapter_path = args.adapter or "snakepit_bridge.adapters.showcase.ShowcaseAdapter"
        run_health_check(adapter_path)
        return

    if not args.adapter:
        parser.error("--adapter is required (try --adapter snakepit_bridge.adapters.showcase.ShowcaseAdapter)")

    if not args.elixir_address:
        parser.error(
            "--elixir-address is required (set --elixir-address or SNAKEPIT_GRPC_ADDRESS)"
        )

    maybe_create_process_group()

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
