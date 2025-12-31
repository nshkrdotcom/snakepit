# Streaming Tool Execution Implementation Plan

## Overview

This document outlines the implementation plan for enabling end-to-end streaming tool execution in Snakepit. The changes enable gRPC streaming from external clients through Snakepit's BridgeServer to Python workers and back.

## Summary of Changes

| Priority | Change | File | Status |
|----------|--------|------|--------|
| Required | Implement `ExecuteStreamingTool` | `lib/snakepit/grpc/bridge_server.ex` | Pending |
| Required | Fix timeout parsing bug | `lib/snakepit/grpc/bridge_server.ex` | Pending |
| Required | Fix remote binary parameter decoding | `lib/snakepit/grpc/bridge_server.ex` | Pending |
| Optional | Add `supports_streaming` to InternalToolSpec | `lib/snakepit/bridge/tool_registry.ex` | Optional |

## Architecture

### Current Flow (Unary)

```
Client → BridgeServer.execute_tool/2 → ToolRegistry.get_tool/2 → Worker → Response
```

### New Flow (Streaming)

```
Client → BridgeServer.execute_streaming_tool/2
       → SessionStore.get_session/1
       → ToolRegistry.get_tool/2
       → ensure_streaming_supported/2
       → GRPCClient.execute_streaming_tool/5 (to Python worker)
       → forward_worker_stream/4 (iterate & relay chunks)
       → Client receives ToolChunk stream
```

## Key Components

### 1. ExecuteStreamingTool Implementation (Required)

The current `execute_streaming_tool/2` raises `UNIMPLEMENTED`. The new implementation:

- Validates session and tool existence
- Ensures tool is remote and supports streaming
- Forwards request to Python worker via streaming gRPC
- Relays chunks from worker stream to client stream
- Handles cleanup and error cases

See: [01-execute-streaming-tool.md](./01-execute-streaming-tool.md)

### 2. Timeout Parsing Fix (Required)

The current `tool_call_options/1` has a precedence bug that can return a string instead of a keyword list.

**Bug location:** `lib/snakepit/grpc/bridge_server.ex:366-375`

```elixir
# Current (buggy)
defp tool_call_options(metadata) when is_map(metadata) do
  metadata
  |> Map.get("timeout_ms") ||
    Map.get(metadata, :timeout_ms)
    |> parse_timeout_ms()  # Can return string from first Map.get!
    |> case do
      {:ok, timeout} -> [timeout: timeout]
      :error -> []
    end
end
```

See: [02-timeout-parsing-fix.md](./02-timeout-parsing-fix.md)

### 3. Binary Parameter Decoding Fix (Required)

The current `decode_tool_parameters/2` merges binary params as `{:binary, bytes}` tuples, which breaks JSON encoding for remote forwarding.

**Problem:** Tuples are not JSON-encodable, causing failures when forwarding to remote workers.

**Solution:** Separate decoding for local vs remote tools.

See: [03-binary-parameter-fix.md](./03-binary-parameter-fix.md)

### 4. First-Class `supports_streaming` Field (Optional)

Currently `supports_streaming` is stored in metadata. Adding it as a struct field provides:
- Type safety
- Cleaner access patterns
- Better documentation

See: [04-supports-streaming-field.md](./04-supports-streaming-field.md)

## Implementation Order

1. **Fix timeout parsing** - Independent, small change
2. **Fix binary parameter decoding** - Independent, required for streaming
3. **Implement ExecuteStreamingTool** - Depends on fixes above
4. **Add supports_streaming field** - Optional enhancement

## Testing Strategy

Each change should follow TDD:

1. Write failing tests first
2. Implement minimum code to pass
3. Refactor while keeping tests green
4. Run full test suite
5. Run dialyzer and credo

## Files Modified

| File | Changes |
|------|---------|
| `lib/snakepit/grpc/bridge_server.ex` | Main implementation + fixes |
| `lib/snakepit/bridge/tool_registry.ex` | Optional: add `supports_streaming` field |
| `test/snakepit/grpc/bridge_server_test.exs` | New streaming tests |
| `guides/streaming.md` | Documentation updates |
| `examples/` | New streaming example |
| `README.md` | Version update |
| `CHANGELOG.md` | Release notes |
| `mix.exs` | Version bump to 0.8.5 |

## Dependencies

### Snakebridge (Python) Dependencies

These Snakepit changes are **independent** and should be done first. The following Snakebridge changes depend on them:

- Snakebridge streaming handler implementation
- Python adapter streaming support
- End-to-end integration tests

## Success Criteria

- [ ] All existing tests pass
- [ ] New streaming tests pass
- [ ] No dialyzer warnings
- [ ] No credo issues
- [ ] Documentation updated
- [ ] Examples work correctly
- [ ] CHANGELOG updated
- [ ] Version bumped to 0.8.5
