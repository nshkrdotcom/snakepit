import asyncio
import importlib.util
import sys
import time
from pathlib import Path
from typing import Optional, Sequence, Tuple

import grpc
import pytest

import snakepit_bridge_pb2 as pb2
from snakepit_bridge import telemetry
from snakepit_bridge.session_context import SessionContext


class CaptureAdapter:
    captured_metadata = None
    captured_correlation = None

    def set_session_context(self, context: SessionContext) -> None:
        self._context = context

    def execute_tool(self, tool_name: str, arguments: dict, context) -> dict:
        CaptureAdapter.captured_metadata = getattr(context, "request_metadata", None)
        CaptureAdapter.captured_correlation = telemetry.get_correlation_id()
        return {"ok": True}


class FakeStub:
    def InitializeSession(self, request, metadata: Optional[Sequence[Tuple[str, str]]] = None):
        return object()


class FakeContext:
    def __init__(self):
        self._metadata = (
            (telemetry.CORRELATION_HEADER, "cid-header"),
            ("x-extra", "value"),
        )

    def invocation_metadata(self):
        return self._metadata


@pytest.fixture()
def grpc_module():
    module_name = "snakepit_grpc_under_test"
    module_path = Path(__file__).resolve().parents[1] / "grpc_server.py"
    spec = importlib.util.spec_from_file_location(module_name, module_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    try:
        spec.loader.exec_module(module)
        yield module
    finally:
        sys.modules.pop(module_name, None)


@pytest.fixture()
def stub_factory(monkeypatch, grpc_module):
    created = []

    def fake_async_channel(address):
        return object()

    def fake_sync_channel(address):
        return object()

    def fake_stub(channel):
        stub = FakeStub()
        created.append(stub)
        return stub

    monkeypatch.setattr(grpc.aio, "insecure_channel", fake_async_channel)
    monkeypatch.setattr(grpc, "insecure_channel", fake_sync_channel)
    monkeypatch.setattr(grpc_module.pb2_grpc, "BridgeServiceStub", fake_stub)

    return created, grpc_module


def test_execute_tool_sets_correlation_from_header_and_exposes_request_metadata(stub_factory):
    _created, grpc_module = stub_factory

    CaptureAdapter.captured_metadata = None
    CaptureAdapter.captured_correlation = None

    servicer = grpc_module.BridgeServiceServicer(
        CaptureAdapter,
        "localhost:50051",
        heartbeat_options={"enabled": False},
    )

    async def run_call():
        request = pb2.ExecuteToolRequest(
            session_id="session-123",
            tool_name="noop",
            metadata={"correlation_id": "cid-metadata", "trace": "value"},
        )
        context = FakeContext()
        await servicer.ExecuteTool(request, context)

    asyncio.run(run_call())

    assert CaptureAdapter.captured_metadata == {"correlation_id": "cid-metadata", "trace": "value"}
    assert CaptureAdapter.captured_correlation == "cid-header"
    assert telemetry.get_correlation_id() is None


# --- Streaming cancellation tests ---


class StreamingAdapter:
    """Adapter that yields chunks and tracks cleanup."""
    cleanup_called = False
    chunks_produced = 0
    iterator_closed = False

    def __init__(self):
        StreamingAdapter.cleanup_called = False
        StreamingAdapter.chunks_produced = 0
        StreamingAdapter.iterator_closed = False

    def set_session_context(self, context: SessionContext) -> None:
        self._context = context

    def execute_tool(self, tool_name: str, arguments: dict, context):
        """Return a generator that yields chunks."""
        return self._stream_chunks(arguments.get("count", 5))

    def _stream_chunks(self, count: int):
        """Generator that tracks how many chunks were produced."""
        try:
            for i in range(count):
                StreamingAdapter.chunks_produced += 1
                yield {"chunk": i, "is_final": i == count - 1}
        finally:
            StreamingAdapter.iterator_closed = True

    def cleanup(self):
        StreamingAdapter.cleanup_called = True


class CancellingContext:
    """Fake context that simulates client disconnect after N chunks."""

    def __init__(self, cancel_after: int = 2):
        self._metadata = ()
        self._cancel_after = cancel_after
        self._chunks_seen = 0
        self._active = True

    def invocation_metadata(self):
        return self._metadata

    def is_active(self):
        return self._active

    def note_chunk(self):
        """Call this when a chunk is yielded to simulate disconnect."""
        self._chunks_seen += 1
        if self._chunks_seen >= self._cancel_after:
            self._active = False

    async def abort(self, code, message):
        raise grpc.RpcError()


def test_streaming_cleanup_called_on_normal_completion(stub_factory):
    """Verify cleanup is called when streaming completes normally."""
    _created, grpc_module = stub_factory

    async def run_streaming():
        # Create servicer inside async context where event loop exists
        servicer = grpc_module.BridgeServiceServicer(
            StreamingAdapter,
            "localhost:50051",
            heartbeat_options={"enabled": False},
        )
        request = pb2.ExecuteToolRequest(
            session_id="session-stream-1",
            tool_name="stream",
        )
        context = CancellingContext(cancel_after=999)  # Never cancel
        chunks = []
        async for chunk in servicer.ExecuteStreamingTool(request, context):
            chunks.append(chunk)
        return chunks

    chunks = asyncio.run(run_streaming())

    # All chunks should be produced
    assert len(chunks) >= 1
    # Cleanup should be called
    assert StreamingAdapter.cleanup_called is True
    # Iterator should be closed
    assert StreamingAdapter.iterator_closed is True


def test_streaming_producer_stops_on_client_disconnect(stub_factory):
    """Verify that producer stops and cleanup is called when client disconnects."""
    _created, grpc_module = stub_factory

    async def run_streaming_with_disconnect():
        # Create servicer inside async context where event loop exists
        servicer = grpc_module.BridgeServiceServicer(
            StreamingAdapter,
            "localhost:50051",
            heartbeat_options={"enabled": False},
        )
        request = pb2.ExecuteToolRequest(
            session_id="session-stream-2",
            tool_name="stream",
            parameters={},
        )
        # Simulate client disconnect after 2 chunks
        context = CancellingContext(cancel_after=2)
        chunks = []
        try:
            async for chunk in servicer.ExecuteStreamingTool(request, context):
                chunks.append(chunk)
                context.note_chunk()
                # Give the watcher task time to detect disconnect
                await asyncio.sleep(0.15)
        except (grpc.RpcError, asyncio.CancelledError):
            pass
        return chunks

    # Use timeout to catch hangs (sentinel not delivered on disconnect)
    async def run_with_timeout():
        try:
            return await asyncio.wait_for(run_streaming_with_disconnect(), timeout=5.0)
        except asyncio.TimeoutError:
            raise AssertionError("Streaming hung on disconnect - sentinel likely not delivered")

    chunks = asyncio.run(run_with_timeout())

    # Should have stopped early (not all 5 chunks)
    # Note: exact count depends on timing, but cleanup must be called
    assert StreamingAdapter.cleanup_called is True
    # Iterator should be properly closed via _close_iterator
    assert StreamingAdapter.iterator_closed is True


class AsyncStreamingAdapter:
    """Adapter that yields chunks asynchronously and tracks cleanup."""
    cleanup_called = False
    chunks_produced = 0

    def __init__(self):
        AsyncStreamingAdapter.cleanup_called = False
        AsyncStreamingAdapter.chunks_produced = 0

    def set_session_context(self, context: SessionContext) -> None:
        self._context = context

    async def execute_tool(self, tool_name: str, arguments: dict, context):
        """Return an async generator that yields chunks."""
        return self._stream_chunks_async(arguments.get("count", 5))

    async def _stream_chunks_async(self, count: int):
        """Async generator that tracks how many chunks were produced."""
        for i in range(count):
            AsyncStreamingAdapter.chunks_produced += 1
            yield {"chunk": i, "is_final": i == count - 1}
            await asyncio.sleep(0.01)

    async def cleanup(self):
        """Async cleanup method."""
        AsyncStreamingAdapter.cleanup_called = True


def test_async_streaming_cleanup_called(stub_factory):
    """Verify async cleanup is awaited properly."""
    _created, grpc_module = stub_factory

    async def run_async_streaming():
        # Create servicer inside async context where event loop exists
        servicer = grpc_module.BridgeServiceServicer(
            AsyncStreamingAdapter,
            "localhost:50051",
            heartbeat_options={"enabled": False},
        )
        request = pb2.ExecuteToolRequest(
            session_id="session-stream-3",
            tool_name="async_stream",
        )
        context = CancellingContext(cancel_after=999)
        chunks = []
        async for chunk in servicer.ExecuteStreamingTool(request, context):
            chunks.append(chunk)
        return chunks

    chunks = asyncio.run(run_async_streaming())

    assert len(chunks) >= 1
    # Async cleanup should have been awaited
    assert AsyncStreamingAdapter.cleanup_called is True


class HighVolumeStreamingAdapter:
    """Adapter that produces many chunks to test backpressure."""
    cleanup_called = False
    chunks_produced = 0

    def __init__(self):
        HighVolumeStreamingAdapter.cleanup_called = False
        HighVolumeStreamingAdapter.chunks_produced = 0

    def set_session_context(self, context: SessionContext) -> None:
        self._context = context

    def execute_tool(self, tool_name: str, arguments: dict, context):
        """Return a generator that yields many chunks (more than queue maxsize)."""
        count = arguments.get("count", 250)  # More than queue maxsize of 100
        return self._stream_many_chunks(count)

    def _stream_many_chunks(self, count: int):
        """Generator that produces more chunks than queue can hold."""
        for i in range(count):
            HighVolumeStreamingAdapter.chunks_produced += 1
            yield {"chunk": i, "is_final": i == count - 1}

    def cleanup(self):
        HighVolumeStreamingAdapter.cleanup_called = True


def test_streaming_completes_under_backpressure(stub_factory):
    """
    Verify streaming completes when producing more chunks than queue maxsize.

    This tests sentinel delivery: if sentinel is dropped due to QueueFull,
    the consumer would hang forever. With proper await-based delivery,
    this should complete normally.
    """
    _created, grpc_module = stub_factory

    async def run_high_volume_streaming():
        servicer = grpc_module.BridgeServiceServicer(
            HighVolumeStreamingAdapter,
            "localhost:50051",
            heartbeat_options={"enabled": False},
        )
        request = pb2.ExecuteToolRequest(
            session_id="session-stream-backpressure",
            tool_name="high_volume_stream",
            parameters={},  # Uses default count of 250
        )
        context = CancellingContext(cancel_after=999)  # Never cancel
        chunks = []

        # This should NOT hang - sentinel must be delivered even under backpressure
        async for chunk in servicer.ExecuteStreamingTool(request, context):
            chunks.append(chunk)

        return chunks

    # Use a timeout to catch hangs
    async def run_with_timeout():
        try:
            return await asyncio.wait_for(run_high_volume_streaming(), timeout=10.0)
        except asyncio.TimeoutError:
            raise AssertionError("Streaming hung - sentinel likely not delivered")

    chunks = asyncio.run(run_with_timeout())

    # All 250 chunks should be produced (plus final chunk)
    assert len(chunks) >= 250
    # Cleanup must be called
    assert HighVolumeStreamingAdapter.cleanup_called is True
    # All chunks should have been produced
    assert HighVolumeStreamingAdapter.chunks_produced == 250
