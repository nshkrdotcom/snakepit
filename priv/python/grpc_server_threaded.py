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

import argparse
import asyncio
import inspect
import grpc
import logging
import signal
import sys
import time
import threading
import traceback
from concurrent import futures
from typing import Dict, Optional, Sequence, Tuple
from collections import defaultdict

# Add the package to Python path
sys.path.insert(0, '.')

import snakepit_bridge_pb2 as pb2
import snakepit_bridge_pb2_grpc as pb2_grpc
from snakepit_bridge.session_context import SessionContext
from snakepit_bridge.serialization import TypeSerializer
from snakepit_bridge import telemetry
from google.protobuf.timestamp_pb2 import Timestamp
import json
import pickle

logging.basicConfig(
    format='%(asctime)s - [%(threadName)s] - %(name)s - %(levelname)s - [corr=%(correlation_id)s] %(message)s',
    level=logging.INFO
)

telemetry.setup_tracing()
_log_filter = telemetry.correlation_filter()
logger = logging.getLogger(__name__)
logger.addFilter(_log_filter)
logging.getLogger().addFilter(_log_filter)

logger.info("Loaded grpc_server_threaded.py from %s", __file__)


def _ensure_event_loop() -> asyncio.AbstractEventLoop:
    """Return a running loop or create one to avoid deprecation warnings."""
    try:
        return asyncio.get_running_loop()
    except RuntimeError:
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        return loop


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

    # Variable Operations - All proxied to Elixir

    async def RegisterVariable(self, request, context):
        metadata = context.invocation_metadata()
        with telemetry.otel_span(
            "BridgeService/RegisterVariable",
            context_metadata=metadata,
            attributes={"snakepit.variable": request.name},
        ):
            return await self._proxy_to_elixir("RegisterVariable", request, metadata=metadata)

    async def GetVariable(self, request, context):
        metadata = context.invocation_metadata()
        with telemetry.otel_span(
            "BridgeService/GetVariable",
            context_metadata=metadata,
            attributes={"snakepit.variable": request.variable_identifier},
        ):
            return await self._proxy_to_elixir("GetVariable", request, metadata=metadata)

    async def SetVariable(self, request, context):
        metadata = context.invocation_metadata()
        with telemetry.otel_span(
            "BridgeService/SetVariable",
            context_metadata=metadata,
            attributes={"snakepit.variable": request.variable_identifier},
        ):
            return await self._proxy_to_elixir("SetVariable", request, metadata=metadata)

    async def GetVariables(self, request, context):
        metadata = context.invocation_metadata()
        with telemetry.otel_span(
            "BridgeService/GetVariables",
            context_metadata=metadata,
            attributes={"snakepit.variable_count": len(request.variable_identifiers)},
        ):
            return await self._proxy_to_elixir("GetVariables", request, metadata=metadata)

    async def SetVariables(self, request, context):
        metadata = context.invocation_metadata()
        with telemetry.otel_span(
            "BridgeService/SetVariables",
            context_metadata=metadata,
            attributes={"snakepit.variable_count": len(request.updates)},
        ):
            return await self._proxy_to_elixir("SetVariables", request, metadata=metadata)

    async def ListVariables(self, request, context):
        metadata = context.invocation_metadata()
        with telemetry.otel_span(
            "BridgeService/ListVariables",
            context_metadata=metadata,
            attributes={"snakepit.pattern": request.pattern},
        ):
            return await self._proxy_to_elixir("ListVariables", request, metadata=metadata)

    async def DeleteVariable(self, request, context):
        metadata = context.invocation_metadata()
        with telemetry.otel_span(
            "BridgeService/DeleteVariable",
            context_metadata=metadata,
            attributes={"snakepit.variable": request.variable_identifier},
        ):
            return await self._proxy_to_elixir("DeleteVariable", request, metadata=metadata)

    # Tool Execution - Thread-safe concurrent execution

    async def ExecuteTool(self, request, context):
        """Execute tool with thread-safe handling"""
        request_id = self._record_request_start()
        thread_name = threading.current_thread().name
        self.safety_monitor.record_access("ExecuteTool")
        metadata = context.invocation_metadata()
        start_time = time.time()

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

                # Initialize adapter
                if hasattr(adapter, 'initialize'):
                    if asyncio.iscoroutinefunction(adapter.initialize):
                        await adapter.initialize()
                    else:
                        adapter.initialize()

                # Decode parameters
                arguments = {
                    key: TypeSerializer.decode_any(any_msg)
                    for key, any_msg in request.parameters.items()
                }
                for key, binary_val in request.binary_parameters.items():
                    arguments[key] = pickle.loads(binary_val)

                # Execute tool
                if not hasattr(adapter, 'execute_tool'):
                    raise NotImplementedError("Adapter does not support execute_tool")

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

                # Encode response
                response = pb2.ExecuteToolResponse(success=True)

                # Type inference
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
            response.error_message = str(e)
            return response

        finally:
            self._record_request_end()

    async def ExecuteStreamingTool(self, request, context):
        """Execute streaming tool with thread-safe handling"""
        request_id = self._record_request_start()
        thread_name = threading.current_thread().name
        self.safety_monitor.record_access("ExecuteStreamingTool")
        metadata = context.invocation_metadata()

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

                if hasattr(adapter, 'initialize'):
                    if asyncio.iscoroutinefunction(adapter.initialize):
                        await adapter.initialize()
                    else:
                        adapter.initialize()

                arguments = {
                    key: TypeSerializer.decode_any(any_msg)
                    for key, any_msg in request.parameters.items()
                }
                for key, binary_val in request.binary_parameters.items():
                    arguments[key] = pickle.loads(binary_val)

                if not hasattr(adapter, 'execute_tool'):
                    await context.abort(
                        grpc.StatusCode.UNIMPLEMENTED,
                        "Adapter does not support tool execution"
                    )
                    return

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
                            "[%s] ExecuteStreamingTool #%s raised %s",
                            thread_name,
                            request_id,
                            item,
                            exc_info=True,
                        )
                        await context.abort(grpc.StatusCode.INTERNAL, str(item))
                        return
                    yield item

        except Exception as e:
            logger.error(f"[{thread_name}] ExecuteStreamingTool #{request_id} failed: {e}", exc_info=True)
            await context.abort(grpc.StatusCode.INTERNAL, str(e))

        finally:
            self._record_request_end()

    # Placeholder methods

    async def WatchVariables(self, request, context):
        context.set_code(grpc.StatusCode.UNIMPLEMENTED)
        context.set_details('WatchVariables not implemented')
        return
        yield

    async def AddDependency(self, request, context):
        metadata = context.invocation_metadata()
        logger.debug("Proxying AddDependency (threaded)")
        with telemetry.otel_span(
            "BridgeService/AddDependency",
            context_metadata=metadata,
        ):
            return await self._proxy_to_elixir("AddDependency", request, metadata=metadata)

    async def StartOptimization(self, request, context):
        metadata = context.invocation_metadata()
        logger.debug("Proxying StartOptimization (threaded)")
        with telemetry.otel_span(
            "BridgeService/StartOptimization",
            context_metadata=metadata,
        ):
            return await self._proxy_to_elixir("StartOptimization", request, metadata=metadata)

    async def StopOptimization(self, request, context):
        metadata = context.invocation_metadata()
        logger.debug("Proxying StopOptimization (threaded)")
        with telemetry.otel_span(
            "BridgeService/StopOptimization",
            context_metadata=metadata,
        ):
            return await self._proxy_to_elixir("StopOptimization", request, metadata=metadata)

    async def GetVariableHistory(self, request, context):
        metadata = context.invocation_metadata()
        logger.debug("Proxying GetVariableHistory (threaded)")
        with telemetry.otel_span(
            "BridgeService/GetVariableHistory",
            context_metadata=metadata,
        ):
            return await self._proxy_to_elixir("GetVariableHistory", request, metadata=metadata)

    async def RollbackVariable(self, request, context):
        metadata = context.invocation_metadata()
        logger.debug("Proxying RollbackVariable (threaded)")
        with telemetry.otel_span(
            "BridgeService/RollbackVariable",
            context_metadata=metadata,
        ):
            return await self._proxy_to_elixir("RollbackVariable", request, metadata=metadata)

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
    logger.info(f"GRPC_READY:{actual_port}")
    logger.info(f"✅ Threaded gRPC server ready on port {actual_port} with {max_workers} worker threads")

    # Wait for shutdown
    server_task = asyncio.create_task(server.wait_for_termination())

    try:
        await shutdown_event.wait()
        logger.info("Shutdown signal received")
    finally:
        server_task.cancel()
        await servicer.close()
        await server.stop(0.5)
        logger.info("Server stopped gracefully")


def main():
    parser = argparse.ArgumentParser(description='Snakepit Multi-Threaded gRPC Server')
    parser.add_argument('--port', type=int, default=0, help='Port to listen on')
    parser.add_argument('--adapter', type=str, required=True, help='Adapter class path')
    parser.add_argument('--elixir-address', type=str, required=True, help='Elixir server address')
    parser.add_argument('--max-workers', type=int, default=10, help='Thread pool size')
    parser.add_argument('--thread-safety-check', action='store_true', help='Enable thread safety checks')
    parser.add_argument('--snakepit-run-id', type=str, default='', help='Snakepit run ID')

    args = parser.parse_args()

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
        logger.error(f"Unhandled exception: {type(e).__name__}: {e}")
        traceback.print_exc()
        sys.exit(1)
    finally:
        loop.close()


if __name__ == '__main__':
    main()
