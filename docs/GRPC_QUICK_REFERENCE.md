# gRPC Integration Quick Reference

Keep this page handy when working on Snakepit's gRPC bridge. It summarizes the
current implementation, the critical entry points, and the fastest ways to test
streaming behaviour end-to-end.

## Current State

- ✅ `Snakepit.execute_stream/4` and `execute_in_session_stream/5` stream results
  through the gRPC adapter with full session awareness.
- ✅ `Snakepit.Adapters.GRPCPython` handles request/response and streaming calls
  via `Snakepit.GRPC.Client` with per-worker session IDs.
- ✅ Workers persist the OS-assigned port and expose their live `GRPC.Stub` so BridgeServer can reuse an existing channel (`test/unit/grpc/grpc_worker_ephemeral_port_test.exs`, `test/snakepit/grpc/bridge_server_test.exs`).
- ✅ BridgeServer validates JSON payloads up front and emits descriptive `{:invalid_parameter, key, reason}` tuples on malformed input (`test/snakepit/grpc/bridge_server_test.exs`).
- ✅ SessionStore and bridge registries keep state in `:protected` ETS tables with private DETS handles while enforcing configurable quotas that fail fast with tagged errors (`test/unit/bridge/session_store_test.exs`, `test/unit/pool/process_registry_security_test.exs`).
- ✅ The logger redaction helper summarises sensitive payloads so gRPC logs never leak credentials or large blobs (`test/unit/logger/redaction_test.exs`).
- ✅ Python bridge servers (`priv/python/grpc_server.py` and
  `priv/python/grpc_server_threaded.py`) bridge async generators and synchronous
  iterators into gRPC streams using an `asyncio.Queue`.
- ✅ Regression coverage lives in `test/snakepit/streaming_regression_test.exs` with supplemental unit tests for quotas, channel reuse, and logging redaction.
- ✅ A runnable showcase lives in `examples/stream_progress_demo.exs`.

## Adapter Entry Points

```elixir
def grpc_execute(connection, session_id, command, args, timeout \ 30_000) do
  Snakepit.GRPC.Client.execute_tool(
    connection.channel,
    session_id,
    command,
    args,
    timeout: timeout
  )
end

def grpc_execute_stream(connection, session_id, command, args, callback, timeout \ 300_000)
      when is_function(callback, 1) do
  connection.channel
  |> Snakepit.GRPC.Client.execute_streaming_tool(session_id, command, args, timeout: timeout)
  |> consume_stream(callback)
end
```

`consume_stream/2` decodes each `ToolChunk` into a plain map and
invokes the callback. Payloads always include an `"is_final"` flag and preserve
metadata under `_metadata` when present.

## Python Stream Bridge (Process Mode)

```python
queue: asyncio.Queue = asyncio.Queue()
sentinel = object()

async def produce_chunks():
    ...  # Drain async or sync iterators
    await queue.put(pb2.ToolChunk(...))
    await queue.put(sentinel)

asyncio.create_task(produce_chunks())

while True:
    item = await queue.get()
    if item is sentinel:
        break
    if isinstance(item, Exception):
        await context.abort(grpc.StatusCode.INTERNAL, str(item))
        return
    yield item
```

The threaded server mirrors this logic but supports adapters that can safely run
inside a `ThreadPoolExecutor`.

## Pool/Worker Flow

1. `Snakepit.execute_stream/4` validates the adapter supports gRPC and delegates
   to `Snakepit.Pool.execute_stream/4`.
2. The pool checks out a worker (respecting session affinity) and forwards the
   request to `Snakepit.GRPCWorker.execute_stream/5`.
3. The worker ensures a session is initialised, calls the adapter's
   `grpc_execute_stream/6`, and tracks success/error telemetry.

## Testing & Diagnostics

- Run the regression suite: `mix test test/snakepit/streaming_regression_test.exs`
- Verify port/channel reuse: `mix test test/unit/grpc/grpc_worker_ephemeral_port_test.exs test/snakepit/grpc/bridge_server_test.exs`
- Exercise quota and state protections: `mix test test/unit/bridge/session_store_test.exs test/unit/pool/process_registry_security_test.exs`
- Confirm logging redaction summaries: `mix test test/unit/logger/redaction_test.exs`
- Run Python bridge tests (handles venv, PYTHONPATH, and proto generation): `./test_python.sh`
- Exercise everything interactively:

  ```bash
  MIX_ENV=dev mix run examples/stream_progress_demo.exs
  ```

- Inspect decoded payloads quickly:

  ```elixir
  {:ok, agent} = Agent.start(fn -> [] end)

  Snakepit.execute_stream("stream_progress", %{"steps" => 3}, fn chunk ->
    Agent.update(agent, &[chunk | &1])
  end)

  Agent.get(agent, &Enum.reverse/1)
  ```

## Common Payload Shape

```elixir
%{
  "step" => 1,
  "total" => 5,
  "message" => "Processing step 1/5",
  "progress" => 20.0,
  "is_final" => false,
  "_metadata" => %{}
}
```

Use the `"is_final"` flag to trigger completion handlers without relying on the
stream returning an empty chunk. When the bridge cannot decode `ToolChunk.data`
as JSON it exposes a `"raw_data_base64"` field instead, so you can still inspect
the payload safely.
