import asyncio
import importlib.util
import sys
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
