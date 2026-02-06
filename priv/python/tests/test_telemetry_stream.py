import asyncio
import threading

from snakepit_bridge.telemetry.stream import TelemetryStream


async def _empty_control_stream():
    if False:  # pragma: no cover - keeps this as an async generator
        yield None


async def _collect_events(stream: TelemetryStream, expected_count: int):
    events = []

    async for event in stream.stream(_empty_control_stream(), context=None):
        events.append(event)

        if len(events) >= expected_count:
            stream.close()

    return events


def test_emit_before_stream_attach_is_buffered_and_flushed():
    stream = TelemetryStream(max_buffer=4)

    stream.emit(
        "tool.execution.start",
        {"system_time": 123},
        {"tool": "telemetry_demo", "operation": "buffered"},
        correlation_id="cid-buffered",
    )

    events = asyncio.run(_collect_events(stream, expected_count=1))

    assert len(events) == 1
    event = events[0]

    assert list(event.event_parts) == ["tool", "execution", "start"]
    assert event.measurements["system_time"].int_value == 123
    assert event.metadata["tool"] == "telemetry_demo"
    assert event.metadata["operation"] == "buffered"
    assert event.correlation_id == "cid-buffered"
    assert stream.dropped_count == 0


def test_emit_from_foreign_thread_is_delivered_when_stream_active():
    stream = TelemetryStream(max_buffer=4)

    async def run_test():
        collector = asyncio.create_task(_collect_events(stream, expected_count=1))

        for _ in range(500):
            if stream._loop is not None:
                break
            await asyncio.sleep(0.001)

        assert stream._loop is not None

        def emit_from_thread():
            stream.emit(
                "tool.result_size",
                {"bytes": 42},
                {"tool": "telemetry_demo"},
                correlation_id="cid-thread",
            )

        emitter = threading.Thread(target=emit_from_thread)
        emitter.start()
        emitter.join(timeout=2)

        assert not emitter.is_alive()

        return await collector

    events = asyncio.run(run_test())

    assert len(events) == 1
    event = events[0]
    assert list(event.event_parts) == ["tool", "result_size"]
    assert event.measurements["bytes"].int_value == 42
    assert event.metadata["tool"] == "telemetry_demo"
    assert event.correlation_id == "cid-thread"


def test_pre_stream_buffer_respects_capacity_and_tracks_drops():
    stream = TelemetryStream(max_buffer=1)

    stream.emit(
        "tool.execution.start",
        {"system_time": 1},
        {"index": "first"},
    )

    stream.emit(
        "tool.execution.start",
        {"system_time": 2},
        {"index": "second"},
    )

    events = asyncio.run(_collect_events(stream, expected_count=1))

    assert len(events) == 1
    assert events[0].metadata["index"] == "first"
    assert stream.dropped_count == 1
