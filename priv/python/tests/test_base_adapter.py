import asyncio

import pytest

from snakepit_bridge.base_adapter import BaseAdapter, tool


class DummyResponse:
    def __init__(self, success=True, error_message="failure"):
        self.success = success
        self.error_message = error_message
        self.tool_ids = {"echo": "tool-id"}


class SampleAdapter(BaseAdapter):
    @tool(description="Echo back text")
    def echo(self, text: str) -> str:
        return text


class _AwaitableStub:
    def RegisterTools(self, request):  # pragma: no cover - implicit await exercised in tests
        async def _response():
            return DummyResponse()

        return _response()


class _UnaryUnaryStub:
    class _Call:
        def __init__(self, response):
            self._response = response

        def result(self):
            return self._response

    def RegisterTools(self, request):
        return self._Call(DummyResponse())


class _PlainStub:
    def RegisterTools(self, request):
        return DummyResponse()


@pytest.mark.asyncio
async def test_register_with_session_async_accepts_awaitable_stub():
    adapter = SampleAdapter()

    result = await adapter.register_with_session_async("session-1", _AwaitableStub())

    assert "echo" in result


@pytest.mark.asyncio
async def test_register_with_session_async_handles_unary_unary_call():
    adapter = SampleAdapter()

    result = await adapter.register_with_session_async("session-2", _UnaryUnaryStub())

    assert result == ["echo"]


@pytest.mark.asyncio
async def test_register_with_session_async_handles_plain_response():
    adapter = SampleAdapter()

    result = await adapter.register_with_session_async("session-3", _PlainStub())

    assert result == ["echo"]


@pytest.mark.asyncio
async def test_coerce_stub_response_rejects_awaitable_inside_running_loop():
    adapter = BaseAdapter()

    async def _resp():
        return DummyResponse()

    coro = _resp()
    try:
        with pytest.raises(RuntimeError):
            adapter._coerce_stub_response(coro)
    finally:
        coro.close()


@pytest.mark.asyncio
async def test__await_stub_response_handles_callable_via_executor():
    adapter = BaseAdapter()

    call_count = {"value": 0}

    def blocking_call():
        call_count["value"] += 1
        return DummyResponse()

    response = await adapter._await_stub_response(blocking_call)

    assert call_count["value"] == 1
    assert isinstance(response, DummyResponse)
