import asyncio
import os

import pytest

from snakepit_bridge.heartbeat import HeartbeatClient, HeartbeatConfig


class _FailingStub:
    def Heartbeat(self, *args, **kwargs):
        raise RuntimeError("intentional test failure")


@pytest.mark.asyncio
async def test_dependent_heartbeat_triggers_self_termination(monkeypatch):
    loop = asyncio.get_running_loop()

    kill_event = asyncio.Event()

    def fake_kill(pid: int, sig: int) -> None:
        kill_event.set()

    def fake_exit(code: int) -> None:  # pragma: no cover - executed via call_later
        return None

    monkeypatch.setattr(os, "kill", fake_kill)
    monkeypatch.setattr(os, "_exit", fake_exit)

    config = HeartbeatConfig(
        enabled=True,
        interval_ms=100,
        timeout_ms=100,
        max_missed_heartbeats=3,
        dependent=True,
    )

    client = HeartbeatClient(_FailingStub(), "test-session", config=config, loop=loop)

    assert client.start() is True

    await asyncio.wait_for(kill_event.wait(), timeout=3.5)

    await client.stop()

    status = client.status()
    assert status["missed_heartbeats"] >= config.max_missed_heartbeats
    assert status["dependent"] is True
