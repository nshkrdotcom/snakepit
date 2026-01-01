#!/usr/bin/env python3
"""
Multi-threaded gRPC bridge server for Snakepit.

This server variant uses a ThreadPoolExecutor to handle multiple concurrent requests
within a single Python process. Designed for Python 3.13+ free-threading mode and
CPU-intensive workloads.

Key differences from grpc_server.py:
- ThreadPoolExecutor with configurable thread count
- Thread-safe adapter requirements
- Concurrent request handling
- Thread safety validation (optional)
- Request tracking per thread

Requirements:
- Python 3.13+ (recommended for free-threading)
- Thread-safe adapter implementation
- Thread-safe ML libraries (NumPy, PyTorch, etc.)
"""

import json
import pickle
import argparse
import asyncio
import inspect
import logging
import os
import signal
import sys
import threading
import time
import traceback
from collections import defaultdict
from concurrent import futures
from typing import Dict, Optional, Sequence, Tuple

from snakepit_bridge.logging_config import configure_logging, get_logger

if __name__ == "__main__":
    configure_logging()

# Add the package to Python path
sys.path.insert(0, '.')

import grpc
import snakepit_bridge_pb2 as pb2
import snakepit_bridge_pb2_grpc as pb2_grpc
from snakepit_bridge.session_context import SessionContext
from snakepit_bridge.serialization import TypeSerializer
from snakepit_bridge import telemetry
from google.protobuf.timestamp_pb2 import Timestamp

telemetry.setup_tracing()
_log_filter = telemetry.correlation_filter()
logger = get_logger("grpc_server_threaded")
logger.addFilter(_log_filter)
logging.getLogger().addFilter(_log_filter)


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


def _ensure_event_loop() -> asyncio.AbstractEventLoop:
    """Return a running loop or create one to avoid deprecation warnings."""
    try:
        return asyncio.get_running_loop()
    except RuntimeError:
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        return loop


def _extract_callsite_context(arguments: Optional[Dict[str, object]], request) -> Dict[str, object]:
    context = {
        "tool_name": getattr(request, "tool_name", None),
        "session_id": getattr(request, "session_id", None),
    }

    if isinstance(arguments, dict):
        for key in ("library", "python_module", "function", "call_type", "payload_version"):
            if key in arguments:
                context[key] = arguments[key]

    return {k: v for k, v in context.items() if v is not None}


def _build_error_payload(exc: Exception, request, arguments: Optional[Dict[str, object]] = None):
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


class ThreadSafetyMonitor:
    """
    Monitor for tracking thread safety issues during execution.

    Detects:
    - Concurrent method access without locking
    - Thread-unsafe library usage
    - Race conditions
    """

    def __init__(self, enabled: bool = False):
        self.enabled = enabled
        self.access_tracker: Dict[str, set] = defaultdict(set)
        self.lock = threading.Lock()
        self.warnings_issued: set = set()

    def record_access(self, method_name: str):
        """Record that current thread accessed a method"""
        if not self.enabled:
            return

        thread_id = threading.get_ident()
        with self.lock:
            self.access_tracker[method_name].add(thread_id)

            # Warn if multiple threads accessing
            if len(self.access_tracker[method_name]) > 1:
                warning_key = f"{method_name}_concurrent"
                if warning_key not in self.warnings_issued:
                    logger.warning(
                        f"⚠️  Concurrent access detected: {method_name} accessed by "
                        f"{len(self.access_tracker[method_name])} different threads"
                    )
                    self.warnings_issued.add(warning_key)

    def get_stats(self) -> dict:
        """Get monitoring statistics"""
        with self.lock:
            return {
                "tracked_methods": len(self.access_tracker),
                "warnings_issued": len(self.warnings_issued),
                "concurrent_accesses": sum(
                    1 for threads in self.access_tracker.values() if len(threads) > 1
                )
            }


class ThreadedBridgeServiceServicer(pb2_grpc.BridgeServiceServicer):
    """
    Multi-threaded gRPC bridge service.

    This servicer can handle multiple concurrent requests by dispatching them
    to a ThreadPoolExecutor. The adapter MUST be thread-safe.

    Thread Safety Requirements:
    - Adapter must implement thread-safe request handling
    - Shared state must use locks or thread-local storage
    - ML libraries must release GIL during computation
    """

    def __init__(
        self,
        adapter_class,
        elixir_address: str,
        max_workers: int,
        enable_safety_checks: bool = False,
        *,
        loop: Optional[asyncio.AbstractEventLoop] = None,
    ):
        logger.info(f"Initializing threaded servicer: max_workers={max_workers}, safety_checks={enable_safety_checks}")

        self.adapter_class = adapter_class
        self.elixir_address = elixir_address
        self.max_workers = max_workers
        self.loop = loop or _ensure_event_loop()
        self.server: Optional[grpc.aio.Server] = None

        # Thread safety monitoring
        self.safety_monitor = ThreadSafetyMonitor(enabled=enable_safety_checks)

        # Request tracking
        self.request_count = 0
        self.active_requests = 0
        self.start_time = time.time()
        self.stats_lock = threading.Lock()

        # Validate adapter thread safety
        self._validate_adapter_thread_safety()

        # Create async channel for proxying
        self.elixir_channel = grpc.aio.insecure_channel(elixir_address)
        self.elixir_stub = pb2_grpc.BridgeServiceStub(self.elixir_channel)

        # Create sync channel for SessionContext
        self.sync_elixir_channel = grpc.insecure_channel(elixir_address)
        self.sync_elixir_stub = pb2_grpc.BridgeServiceStub(self.sync_elixir_channel)

        logger.info(f"✅ Threaded servicer initialized. Ready for concurrent requests.")

    async def _proxy_to_elixir(
        self,
        method_name: str,
        request,
        *,
        metadata: Optional[Sequence[Tuple[str, str]]] = None,
    ):
        """Proxy a request to the Elixir backend with correlation metadata."""

        enriched_metadata = telemetry.outgoing_metadata(metadata)
        stub_method = getattr(self.elixir_stub, method_name)
        call = stub_method(request, metadata=enriched_metadata)

        if inspect.isawaitable(call):
            return await call

        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(None, lambda: call)

    def _validate_adapter_thread_safety(self):
        """Validate that the adapter declares thread safety"""
        if not getattr(self.adapter_class, '__thread_safe__', False):
            logger.error(
                "Adapter %s must declare __thread_safe__ = True to use grpc_server_threaded. "
                "Falling back to process mode is safer than running an unsafe adapter in threads.",
                self.adapter_class.__name__,
            )
            raise ValueError(
                f"Adapter {self.adapter_class.__name__} is not marked thread-safe; "
                "set __thread_safe__ = True or use process mode."
            )

    def _record_request_start(self):
        """Thread-safe request start tracking"""
        with self.stats_lock:
            self.request_count += 1
            self.active_requests += 1
            return self.request_count

    def _record_request_end(self):
        """Thread-safe request end tracking"""
        with self.stats_lock:
            self.active_requests -= 1

    def get_stats(self) -> dict:
        """Get servicer statistics"""
        with self.stats_lock:
            uptime = time.time() - self.start_time
            return {
                "total_requests": self.request_count,
                "active_requests": self.active_requests,
                "max_workers": self.max_workers,
                "uptime_seconds": uptime,
                "requests_per_second": self.request_count / uptime if uptime > 0 else 0,
                "safety_monitor": self.safety_monitor.get_stats()
            }

    async def close(self):
        """Clean up resources"""
        if self.elixir_channel:
            await self.elixir_channel.close()
        if self.sync_elixir_channel:
            self.sync_elixir_channel.close()

    # Health & Session Management

    async def Ping(self, request, context):
        """Health check endpoint"""
        self.safety_monitor.record_access("Ping")
        metadata = context.invocation_metadata()

        with telemetry.otel_span(
            "BridgeService/Ping",
            context_metadata=metadata,
            attributes={"snakepit.thread": threading.current_thread().name},
        ):
            response = pb2.PingResponse()
            response.message = (
                f"Pong from threaded Python [{threading.current_thread().name}]: {request.message}"
            )

            timestamp = Timestamp()
            timestamp.GetCurrentTime()
            response.server_time.CopyFrom(timestamp)

            return response

    async def InitializeSession(self, request, context):
        """Initialize session - proxy to Elixir"""
        self.safety_monitor.record_access("InitializeSession")
        metadata = context.invocation_metadata()
        logger.debug(f"[{threading.current_thread().name}] Proxying InitializeSession: {request.session_id}")

        with telemetry.otel_span(
            "BridgeService/InitializeSession",
            context_metadata=metadata,
            attributes={"snakepit.session_id": request.session_id},
        ):
            return await self._proxy_to_elixir("InitializeSession", request, metadata=metadata)

    async def CleanupSession(self, request, context):
        """Cleanup session - proxy to Elixir"""
        self.safety_monitor.record_access("CleanupSession")
        metadata = context.invocation_metadata()
        logger.debug(f"[{threading.current_thread().name}] Proxying CleanupSession: {request.session_id}")

        with telemetry.otel_span(
            "BridgeService/CleanupSession",
            context_metadata=metadata,
            attributes={"snakepit.session_id": request.session_id},
        ):
            return await self._proxy_to_elixir("CleanupSession", request, metadata=metadata)

    async def GetSession(self, request, context):
        """Get session - proxy to Elixir"""
        metadata = context.invocation_metadata()
        logger.debug(f"[{threading.current_thread().name}] Proxying GetSession: {request.session_id}")

        with telemetry.otel_span(
            "BridgeService/GetSession",
            context_metadata=metadata,
            attributes={"snakepit.session_id": request.session_id},
        ):
            return await self._proxy_to_elixir("GetSession", request, metadata=metadata)

    async def Heartbeat(self, request, context):
        """Heartbeat - proxy to Elixir"""
        metadata = context.invocation_metadata()
        with telemetry.otel_span(
            "BridgeService/Heartbeat",
            context_metadata=metadata,
            attributes={"snakepit.session_id": request.session_id},
        ):
            return await self._proxy_to_elixir("Heartbeat", request, metadata=metadata)

    # Tool Execution - Thread-safe concurrent execution

    async def ExecuteTool(self, request, context):
        """Execute tool with thread-safe handling"""
        request_id = self._record_request_start()
        thread_name = threading.current_thread().name
        self.safety_monitor.record_access("ExecuteTool")
        metadata = context.invocation_metadata()
        start_time = time.time()
        adapter = None

        try:
            with telemetry.otel_span(
                "BridgeService/ExecuteTool",
                context_metadata=metadata,
                attributes={
                    "snakepit.session_id": request.session_id,
                    "snakepit.tool": request.tool_name,
                    "snakepit.thread": thread_name,
                    "snakepit.request_id": request_id,
                },
            ):
                logger.info(
                    f"[{thread_name}] ExecuteTool #{request_id}: {request.tool_name} "
                    f"(session: {request.session_id})"
                )

                # Ensure session exists
                init_request = pb2.InitializeSessionRequest(session_id=request.session_id)
                try:
                    self.sync_elixir_stub.InitializeSession(
                        init_request,
                        metadata=telemetry.outgoing_metadata(metadata),
                    )
                except grpc.RpcError as e:
                    if e.code() != grpc.StatusCode.ALREADY_EXISTS:
                        logger.debug(f"InitializeSession: {e}")

                # Create ephemeral context and adapter
                session_context = SessionContext(
                    self.sync_elixir_stub,
                    request.session_id,
                    request_metadata=dict(request.metadata),
                )
                adapter = self.adapter_class()
                adapter.set_session_context(session_context)

                # Register tools if needed
                if hasattr(adapter, 'register_with_session'):
                    adapter.register_with_session(request.session_id, self.sync_elixir_stub)

                # Initialize adapter (uses isawaitable for robustness)
                if hasattr(adapter, 'initialize'):
                    result = adapter.initialize()
                    if inspect.isawaitable(result):
                        await result

                # Decode parameters
                arguments = {
                    key: TypeSerializer.decode_any(any_msg)
                    for key, any_msg in request.parameters.items()
                }
                # Handle binary parameters - raw bytes by default, pickle only if metadata specifies
                for key, binary_val in request.binary_parameters.items():
                    format_key = f"binary_format:{key}"
                    if request.metadata.get(format_key) == "pickle":
                        arguments[key] = pickle.loads(binary_val)
                    else:
                        # Treat as opaque bytes (images, audio, etc.)
                        arguments[key] = binary_val

                # Execute tool
                if not hasattr(adapter, 'execute_tool'):
                    raise NotImplementedError("Adapter does not support execute_tool")

                # Execute - handle both sync and async
                result = adapter.execute_tool(
                    tool_name=request.tool_name,
                    arguments=arguments,
                    context=session_context
                )
                if inspect.isawaitable(result):
                    result_data = await result
                else:
                    result_data = result

                # Encode response
                response = pb2.ExecuteToolResponse(success=True)

                # Type inference
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
                    result_type = "string"

                any_msg, binary_data = TypeSerializer.encode_any(result_data, result_type)
                response.result.CopyFrom(any_msg)
                if binary_data:
                    response.binary_result = binary_data

                response.execution_time_ms = int((time.time() - start_time) * 1000)

                logger.info(
                    f"[{thread_name}] ExecuteTool #{request_id} completed in "
                    f"{response.execution_time_ms}ms"
                )

                return response

        except Exception as e:
            logger.error(f"[{thread_name}] ExecuteTool #{request_id} failed: {e}", exc_info=True)
            response = pb2.ExecuteToolResponse()
            response.success = False
            response.error_message = json.dumps(
                _build_error_payload(e, request, locals().get("arguments"))
            )
            return response

        finally:
            self._record_request_end()
            # Always cleanup adapter
            if adapter is not None:
                await _maybe_cleanup(adapter)

    async def ExecuteStreamingTool(self, request, context):
        """Execute streaming tool with thread-safe handling"""
        request_id = self._record_request_start()
        thread_name = threading.current_thread().name
        self.safety_monitor.record_access("ExecuteStreamingTool")
        metadata = context.invocation_metadata()
        adapter = None
        stream_iterator = None

        try:
            with telemetry.otel_span(
                "BridgeService/ExecuteStreamingTool",
                context_metadata=metadata,
                attributes={
                    "snakepit.session_id": request.session_id,
                    "snakepit.tool": request.tool_name,
                    "snakepit.thread": thread_name,
                    "snakepit.request_id": request_id,
                },
            ):
                logger.info(
                    f"[{thread_name}] ExecuteStreamingTool #{request_id}: {request.tool_name}"
                )

                # Similar to ExecuteTool but yields chunks
                init_request = pb2.InitializeSessionRequest(session_id=request.session_id)
                try:
                    self.sync_elixir_stub.InitializeSession(
                        init_request,
                        metadata=telemetry.outgoing_metadata(metadata),
                    )
                except grpc.RpcError as e:
                    if e.code() != grpc.StatusCode.ALREADY_EXISTS:
                        logger.debug(f"InitializeSession: {e}")

                session_context = SessionContext(
                    self.sync_elixir_stub,
                    request.session_id,
                    request_metadata=dict(request.metadata),
                )
                adapter = self.adapter_class()
                adapter.set_session_context(session_context)

                if hasattr(adapter, 'register_with_session'):
                    adapter.register_with_session(request.session_id, self.sync_elixir_stub)

                # Initialize adapter (uses isawaitable for robustness)
                if hasattr(adapter, 'initialize'):
                    result = adapter.initialize()
                    if inspect.isawaitable(result):
                        await result

                arguments = {
                    key: TypeSerializer.decode_any(any_msg)
                    for key, any_msg in request.parameters.items()
                }
                # Handle binary parameters - raw bytes by default, pickle only if metadata specifies
                for key, binary_val in request.binary_parameters.items():
                    format_key = f"binary_format:{key}"
                    if request.metadata.get(format_key) == "pickle":
                        arguments[key] = pickle.loads(binary_val)
                    else:
                        # Treat as opaque bytes (images, audio, etc.)
                        arguments[key] = binary_val

                if not hasattr(adapter, 'execute_tool'):
                    await context.abort(
                        grpc.StatusCode.UNIMPLEMENTED,
                        "Adapter does not support tool execution"
                    )
                    return

                # Execute - handle both sync and async
                result = adapter.execute_tool(
                    tool_name=request.tool_name,
                    arguments=arguments,
                    context=session_context
                )
                if inspect.isawaitable(result):
                    stream_iterator = await result
                else:
                    stream_iterator = result

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
                                "[%s] ExecuteStreamingTool #%s raised %s",
                                thread_name,
                                request_id,
                                item,
                                exc_info=True,
                            )
                            cancelled.set()  # Signal producer to stop
                            await context.abort(
                                grpc.StatusCode.INTERNAL,
                                json.dumps(_build_error_payload(item, request, locals().get("arguments"))),
                            )
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
            logger.error(f"[{thread_name}] ExecuteStreamingTool #{request_id} failed: {e}", exc_info=True)
            # Cleanup on early failure
            await _close_iterator(stream_iterator)
            await _maybe_cleanup(adapter)
            await context.abort(
                grpc.StatusCode.INTERNAL,
                json.dumps(_build_error_payload(e, request, locals().get("arguments"))),
            )

        finally:
            self._record_request_end()

    def set_server(self, server):
        """Set server reference for graceful shutdown"""
        self.server = server


async def wait_for_elixir_server(elixir_address: str, max_retries: int = 30, initial_delay: float = 0.05):
    """Wait for Elixir gRPC server to become available"""
    delay = initial_delay
    for attempt in range(1, max_retries + 1):
        try:
            channel = grpc.aio.insecure_channel(elixir_address)
            stub = pb2_grpc.BridgeServiceStub(channel)
            request = pb2.PingRequest(message="connection_test")
            await asyncio.wait_for(stub.Ping(request), timeout=1.0)
            await channel.close()
            logger.info(f"✅ Connected to Elixir server at {elixir_address} after {attempt} attempt(s)")
            return True
        except (grpc.aio.AioRpcError, asyncio.TimeoutError, Exception) as e:
            if attempt < max_retries:
                logger.debug(f"Elixir server not ready (attempt {attempt}/{max_retries}), retrying in {delay:.2f}s...")
                await asyncio.sleep(delay)
                delay = min(delay * 2, 2.0)
            else:
                logger.error(f"❌ Failed to connect to Elixir server after {max_retries} attempts")
                return False
    return False


async def serve_threaded(
    port: int,
    adapter_module: str,
    elixir_address: str,
    max_workers: int,
    enable_safety_checks: bool,
    shutdown_event: asyncio.Event
):
    """Start multi-threaded gRPC server"""
    logger.info(f"🚀 Starting threaded gRPC server: port={port}, max_workers={max_workers}")

    # Wait for Elixir server
    if not await wait_for_elixir_server(elixir_address):
        logger.error("Cannot start: Elixir server unavailable")
        sys.exit(1)

    # Import adapter
    module_parts = adapter_module.split('.')
    module_name = '.'.join(module_parts[:-1])
    class_name = module_parts[-1]

    try:
        module = __import__(module_name, fromlist=[class_name])
        adapter_class = getattr(module, class_name)
    except (ImportError, AttributeError) as e:
        logger.error(f"Failed to import adapter {adapter_module}: {e}")
        sys.exit(1)

    # Create server with ThreadPoolExecutor
    server = grpc.aio.server(
        futures.ThreadPoolExecutor(max_workers=max_workers),
        options=[
            ('grpc.max_send_message_length', 100 * 1024 * 1024),
            ('grpc.max_receive_message_length', 100 * 1024 * 1024),
            ('grpc.max_concurrent_streams', max_workers),
            ('grpc.so_reuseport', 0),
        ]
    )

    loop = asyncio.get_running_loop()

    servicer = ThreadedBridgeServiceServicer(
        adapter_class,
        elixir_address,
        max_workers,
        enable_safety_checks,
        loop=loop,
    )
    servicer.set_server(server)

    pb2_grpc.add_BridgeServiceServicer_to_server(servicer, server)

    # Bind to port
    try:
        actual_port = server.add_insecure_port(f'[::]:{port}')
        if actual_port == 0 and port != 0:
            logger.error(f"Failed to bind to port {port}")
            sys.exit(1)
    except Exception as e:
        logger.error(f"Exception binding to port {port}: {e}")
        sys.exit(1)

    await server.start()

    # Signal ready
    _signal_ready(actual_port)
    logger.info(f"✅ Threaded gRPC server ready on port {actual_port} with {max_workers} worker threads")

    # Wait for shutdown
    server_task = asyncio.create_task(server.wait_for_termination())

    try:
        await shutdown_event.wait()
        logger.info("Shutdown signal received")
    finally:
        # 1. Close servicer first
        await servicer.close()

        # 2. Stop server with grace period
        await server.stop(2.0)

        # 3. Await server termination task to complete naturally (event-driven).
        #    Only cancel if it doesn't complete in time (timeout as safety net).
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

        logger.info("Server stopped gracefully")


def main():
    configure_logging()
    logger.debug("Loaded grpc_server_threaded.py from %s", __file__)

    parser = argparse.ArgumentParser(description='Snakepit Multi-Threaded gRPC Server')
    parser.add_argument('--port', type=int, default=0, help='Port to listen on')
    parser.add_argument('--adapter', type=str, required=True, help='Adapter class path')
    parser.add_argument('--elixir-address', type=str, required=True, help='Elixir server address')
    parser.add_argument('--max-workers', type=int, default=10, help='Thread pool size')
    parser.add_argument('--thread-safety-check', action='store_true', help='Enable thread safety checks')
    parser.add_argument('--snakepit-run-id', type=str, default='', help='Snakepit run ID')

    args = parser.parse_args()

    maybe_create_process_group()

    # Signal handlers
    shutdown_event = None

    def handle_signal(signum, frame):
        if shutdown_event and not shutdown_event.is_set():
            asyncio.get_running_loop().call_soon_threadsafe(shutdown_event.set)

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    # Run server
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    shutdown_event = asyncio.Event()

    try:
        loop.run_until_complete(serve_threaded(
            args.port,
            args.adapter,
            args.elixir_address,
            args.max_workers,
            args.thread_safety_check,
            shutdown_event
        ))
    except BaseException as e:
        logger.exception("Unhandled exception: %s: %s", type(e).__name__, e)
        sys.exit(1)
    finally:
        loop.close()


if __name__ == '__main__':
    main()
