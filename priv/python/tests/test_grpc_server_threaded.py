import asyncio
import importlib.util
import sys
from pathlib import Path
from typing import List, Optional, Sequence, Tuple

import grpc
import pytest

import snakepit_bridge_pb2 as pb2
from snakepit_bridge import telemetry
from snakepit_bridge.session_context import SessionContext


class DummyAdapter:
    __thread_safe__ = True

    def set_session_context(self, context: SessionContext) -> None:  # pragma: no cover - simplified for tests
        self._context = context


class FakeAwaitable:
    def __init__(self, value):
        self._value = value

    def __await__(self):
        async def _coro():
            return self._value

        return _coro().__await__()


class FakeStub:
    def __init__(self, channel):
        self.channel = channel
        self.calls: List[Sequence[Tuple[str, str]]] = []

    def InitializeSession(self, request, metadata: Optional[Sequence[Tuple[str, str]]] = None):
        self.calls.append(list(metadata or []))
        return FakeAwaitable(object())


class FakeContext:
    def __init__(self):
        self._metadata = (
            (telemetry.CORRELATION_HEADER, "threaded-cid"),
            ("x-custom-header", "value"),
        )

    def invocation_metadata(self):
        return self._metadata


@pytest.fixture()
def threaded_module():
    module_name = "snakepit_threaded_under_test"
    module_path = Path(__file__).resolve().parents[1] / "grpc_server_threaded.py"
    spec = importlib.util.spec_from_file_location(module_name, module_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    try:
        spec.loader.exec_module(module)
        yield module
    finally:
        sys.modules.pop(module_name, None)


@pytest.fixture()
def stub_factory(monkeypatch, threaded_module):
    created = []

    def fake_async_channel(address):
        return object()

    def fake_sync_channel(address):
        return object()

    def fake_stub(channel):
        stub = FakeStub(channel)
        created.append(stub)
        return stub

    monkeypatch.setattr(grpc.aio, "insecure_channel", fake_async_channel)
    monkeypatch.setattr(grpc, "insecure_channel", fake_sync_channel)
    monkeypatch.setattr(threaded_module.pb2_grpc, "BridgeServiceStub", fake_stub)

    return created, threaded_module


def test_initialize_session_propagates_correlation(stub_factory):
    created, threaded_module = stub_factory

    servicer = threaded_module.ThreadedBridgeServiceServicer(
        DummyAdapter,
        "localhost:50051",
        max_workers=4,
    )

    async def run_call():
        request = pb2.InitializeSessionRequest(session_id="session-123")
        context = FakeContext()
        await servicer.InitializeSession(request, context)

    asyncio.run(run_call())

    async_stub = created[0]
    assert any(
        header == telemetry.CORRELATION_HEADER and value == "threaded-cid"
        for header, value in async_stub.calls[-1]
    )
    assert telemetry.get_correlation_id() is None
