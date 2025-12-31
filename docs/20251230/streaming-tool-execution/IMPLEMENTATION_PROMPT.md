# Streaming Tool Execution Implementation - Agent Prompt

## Mission

Implement end-to-end streaming tool execution in Snakepit's BridgeServer following TDD principles. This enables gRPC streaming from external clients through Snakepit to Python workers and back.

## Required Reading

Before starting implementation, read and understand these files:

### Source Files (Read First)

1. **`lib/snakepit/grpc/bridge_server.ex`** - Main file to modify
   - Current `execute_streaming_tool/2` implementation (lines 473-488) - stub to replace
   - `execute_tool/2` implementation (lines 134-172) - pattern to follow
   - `execute_tool_handler/4` (lines 174-227) - understand local vs remote handling
   - `decode_tool_parameters/2` (lines 229-251) - understand parameter decoding
   - `tool_call_options/1` (lines 366-375) - BUG to fix
   - `forward_tool_to_worker/5` (lines 331-364) - understand worker forwarding

2. **`lib/snakepit/grpc/client.ex`** - GRPC client facade
   - `execute_streaming_tool/5` (lines 59-91) - already implemented

3. **`lib/snakepit/grpc/client_impl.ex`** - Real GRPC client
   - `execute_streaming_tool/5` (lines 178-188) - already implemented
   - `prepare_execute_stream_request/5` (lines 348-358) - request preparation

4. **`lib/snakepit/bridge/tool_registry.ex`** - Tool storage
   - `InternalToolSpec` struct (lines 1-28)
   - `get_tool/2` (lines 87-92)

5. **`lib/snakepit/grpc/generated/snakepit_bridge.pb.ex`** - Protobuf messages
   - Find `ToolChunk` message definition

### Documentation Files

6. **`docs/20251230/streaming-tool-execution/00-overview.md`** - Overview of all changes
7. **`docs/20251230/streaming-tool-execution/01-execute-streaming-tool.md`** - Main implementation
8. **`docs/20251230/streaming-tool-execution/02-timeout-parsing-fix.md`** - Bug fix
9. **`docs/20251230/streaming-tool-execution/03-binary-parameter-fix.md`** - Bug fix

### Test Files

10. **`test/snakepit/grpc/bridge_server_test.exs`** - Existing tests to extend

### Guides to Update

11. **`guides/streaming.md`** - Streaming documentation
12. **`README.md`** - Main README (version reference)

### Examples to Reference

13. **`examples/grpc_streaming.exs`** - Existing streaming example
14. **`examples/stream_progress_demo.exs`** - Another streaming example

## Implementation Order

Follow this exact order to ensure each change builds on the previous:

### Phase 1: Bug Fixes (Independent, Required)

#### 1.1 Fix Timeout Parsing Bug

**File:** `lib/snakepit/grpc/bridge_server.ex`

**Current code (lines 366-375):**
```elixir
defp tool_call_options(metadata) when is_map(metadata) do
  metadata
  |> Map.get("timeout_ms") ||
    Map.get(metadata, :timeout_ms)
    |> parse_timeout_ms()
    |> case do
      {:ok, timeout} -> [timeout: timeout]
      :error -> []
    end
end
```

**Replace with:**
```elixir
defp tool_call_options(metadata) when is_map(metadata) do
  value = Map.get(metadata, "timeout_ms") || Map.get(metadata, :timeout_ms)

  case parse_timeout_ms(value) do
    {:ok, timeout} -> [timeout: timeout]
    :error -> []
  end
end
```

**Test to add** (in `bridge_server_test.exs`):
```elixir
test "execute_tool handles string timeout_ms in metadata", %{session_id: session_id} do
  ensure_tool_registry_started()
  ensure_started(Snakepit.Pool.Registry)
  {:ok, _session} = SessionStore.create_session(session_id)

  worker_id = "timeout_test_#{System.unique_integer([:positive])}"
  {:ok, _worker_pid} = start_supervised({ChannelWorker, {self(), worker_id}})

  :ok = ToolRegistry.register_python_tool(session_id, "timeout_tool", worker_id, %{})

  request = %ExecuteToolRequest{
    session_id: session_id,
    tool_name: "timeout_tool",
    parameters: %{},
    metadata: %{"timeout_ms" => "5000"}
  }

  response = BridgeServer.execute_tool(request, nil)
  assert %ExecuteToolResponse{success: true} = response

  assert_receive {:grpc_client_execute_tool, ^session_id, "timeout_tool", %{}, opts}, 1_000
  # If this passes, the bug is fixed - previously would crash
end
```

#### 1.2 Fix Binary Parameter Decoding

**File:** `lib/snakepit/grpc/bridge_server.ex`

**Add new helper function** (after `decode_tool_parameters/2`):
```elixir
defp decode_remote_tool_parameters(params, binary_params) do
  with {:ok, decoded} <- decode_tool_parameters(params, %{}),
       :ok <- validate_binary_parameters(binary_params || %{}) do
    {:ok, decoded}
  end
end

defp validate_binary_parameters(binary_params) when is_map(binary_params) do
  Enum.reduce_while(binary_params, :ok, fn {key, value}, :ok ->
    if is_binary(value) do
      {:cont, :ok}
    else
      {:halt, {:error, {:invalid_parameter, normalize_param_key(key), :not_binary}}}
    end
  end)
end

defp validate_binary_parameters(_), do: :ok
```

**Update `execute_tool_handler/4` for remote tools** (around line 185):
Change:
```elixir
with {:ok, params} <- decode_tool_parameters(request.parameters, request.binary_parameters),
```
To:
```elixir
with {:ok, params} <- decode_remote_tool_parameters(request.parameters, request.binary_parameters),
```

### Phase 2: Streaming Implementation (Core Feature)

#### 2.1 Add ToolChunk Alias

**File:** `lib/snakepit/grpc/bridge_server.ex`

Add `ToolChunk` to the alias list (around line 12):
```elixir
alias Snakepit.Bridge.{
  CleanupSessionRequest,
  CleanupSessionResponse,
  ExecuteElixirToolRequest,
  ExecuteElixirToolResponse,
  ExecuteToolRequest,
  ExecuteToolResponse,
  GetExposedElixirToolsRequest,
  GetExposedElixirToolsResponse,
  GetSessionRequest,
  GetSessionResponse,
  HeartbeatRequest,
  HeartbeatResponse,
  InitializeSessionResponse,
  ParameterSpec,
  PingRequest,
  PingResponse,
  RegisterToolsRequest,
  RegisterToolsResponse,
  ToolChunk,  # ADD THIS
  ToolSpec
}
```

#### 2.2 Replace `execute_streaming_tool/2`

**File:** `lib/snakepit/grpc/bridge_server.ex`

Replace the entire function (lines 473-488) with the implementation from `01-execute-streaming-tool.md`.

#### 2.3 Add All Helper Functions

Add these private functions after the existing helpers. See `01-execute-streaming-tool.md` for full implementations:

- `ensure_streaming_supported/2`
- `tool_supports_streaming?/1`
- `execute_remote_stream/5`
- `forward_streaming_tool_to_worker/4`
- `normalize_stream_response/1`
- `forward_worker_stream/4`
- `normalize_stream_item/1`
- `maybe_decorate_final_chunk/3`
- `send_synthetic_final_chunk/4`
- `raise_streaming_rpc_error/2`

### Phase 3: Tests

#### 3.1 Add Streaming Tests

**File:** `test/snakepit/grpc/bridge_server_test.exs`

Add a new describe block with these tests:

```elixir
describe "execute_streaming_tool/2" do
  test "raises UNIMPLEMENTED for local tools", %{session_id: session_id} do
    ensure_tool_registry_started()
    {:ok, _session} = SessionStore.create_session(session_id)

    :ok = ToolRegistry.register_elixir_tool(
      session_id,
      "local_tool",
      fn _params -> {:ok, :ok} end
    )

    request = %ExecuteToolRequest{
      session_id: session_id,
      tool_name: "local_tool",
      parameters: %{},
      metadata: %{}
    }

    error = assert_raise GRPC.RPCError, fn ->
      BridgeServer.execute_streaming_tool(request, nil)
    end

    assert error.status == Status.unimplemented()
    assert String.contains?(error.message, "Streaming execution is not enabled")
  end

  test "raises NOT_FOUND for non-existent session" do
    request = %ExecuteToolRequest{
      session_id: "non_existent_session",
      tool_name: "any_tool",
      parameters: %{},
      metadata: %{}
    }

    error = assert_raise GRPC.RPCError, fn ->
      BridgeServer.execute_streaming_tool(request, nil)
    end

    assert error.status == Status.not_found()
  end

  test "raises UNIMPLEMENTED for remote tool without streaming support", %{session_id: session_id} do
    ensure_tool_registry_started()
    ensure_started(Snakepit.Pool.Registry)
    {:ok, _session} = SessionStore.create_session(session_id)

    worker_id = "no_stream_worker_#{System.unique_integer([:positive])}"
    {:ok, _worker_pid} = start_supervised({ChannelWorker, {self(), worker_id}})

    :ok = ToolRegistry.register_python_tool(
      session_id,
      "no_stream_tool",
      worker_id,
      %{"supports_streaming" => "false"}
    )

    request = %ExecuteToolRequest{
      session_id: session_id,
      tool_name: "no_stream_tool",
      parameters: %{},
      metadata: %{}
    }

    error = assert_raise GRPC.RPCError, fn ->
      BridgeServer.execute_streaming_tool(request, nil)
    end

    assert error.status == Status.unimplemented()
  end

  test "forwards streaming request to worker for streaming-enabled tool", %{session_id: session_id} do
    ensure_tool_registry_started()
    ensure_started(Snakepit.Pool.Registry)
    {:ok, _session} = SessionStore.create_session(session_id)

    worker_id = "stream_worker_#{System.unique_integer([:positive])}"
    {:ok, _worker_pid} = start_supervised({ChannelWorker, {self(), worker_id}})

    :ok = ToolRegistry.register_python_tool(
      session_id,
      "stream_tool",
      worker_id,
      %{"supports_streaming" => "true"}
    )

    request = %ExecuteToolRequest{
      session_id: session_id,
      tool_name: "stream_tool",
      parameters: %{},
      metadata: %{}
    }

    # The mock stream - need to implement proper GRPC stream mock
    mock_stream = nil

    # Execute - should call the mock client
    _result = BridgeServer.execute_streaming_tool(request, mock_stream)

    assert_receive {:grpc_client_execute_streaming_tool, ^session_id, "stream_tool", %{}, _opts}, 1_000
  end
end
```

### Phase 4: Documentation Updates

#### 4.1 Update `guides/streaming.md`

Add a section about server-side streaming:

```markdown
## Server-Side Streaming Implementation (v0.8.5+)

Starting in v0.8.5, Snakepit's BridgeServer fully implements `ExecuteStreamingTool`,
enabling end-to-end gRPC streaming from external clients through to Python workers.

### Requirements for Streaming Tools

1. Tool must be a **remote** (Python) tool
2. Tool must have `supports_streaming: true` in metadata
3. Python adapter must implement the streaming tool as a generator

### Enabling a Tool for Streaming

In your Python adapter:

\`\`\`python
@tool(description="Stream results", supports_streaming=True)
def my_streaming_tool(self, param: str):
    for i in range(10):
        yield {"step": i, "result": f"Processing {param}"}
\`\`\`

The tool will be registered with streaming support automatically.
```

#### 4.2 Update `README.md`

Change version reference from `0.8.4` to `0.8.5`:
```elixir
{:snakepit, "~> 0.8.5"}
```

#### 4.3 Update `mix.exs`

Change `@version` from `"0.8.4"` to `"0.8.5"`.

#### 4.4 Update `CHANGELOG.md`

Add entry at the top under `## [Unreleased]`:

```markdown
## [0.8.5] - 2025-12-30

### Added
- **ExecuteStreamingTool Implementation** - Full gRPC streaming support in BridgeServer
  - End-to-end streaming from clients through to Python workers
  - Automatic final chunk injection if worker doesn't send one
  - Execution time metadata on final chunks
  - Proper error handling for streaming failures

### Fixed
- **Timeout Parsing Bug** - Fixed precedence issue in `tool_call_options/1` that caused string timeout values to bypass parsing
- **Binary Parameter Encoding** - Fixed remote tool execution to properly handle binary parameters without attempting JSON encoding of tuples
```

### Phase 5: Examples

#### 5.1 Create New Example

**File:** `examples/execute_streaming_tool_demo.exs`

```elixir
#!/usr/bin/env elixir

# Demo: ExecuteStreamingTool via BridgeServer
#
# This example demonstrates the new streaming tool execution capability
# in Snakepit v0.8.5+, where the BridgeServer forwards streaming requests
# to Python workers and relays chunks back to clients.
#
# Prerequisites:
#   - Python adapter with streaming tool registered
#   - Snakepit pool running
#
# Run:
#   mix run examples/execute_streaming_tool_demo.exs

defmodule ExecuteStreamingToolDemo do
  @moduledoc """
  Demonstrates ExecuteStreamingTool for end-to-end gRPC streaming.
  """

  def run do
    IO.puts("=== ExecuteStreamingTool Demo ===\n")

    # Ensure pool is ready
    case Snakepit.Pool.await_ready(:default, 10_000) do
      :ok ->
        demo_progress_streaming()
        demo_data_streaming()
        IO.puts("\n=== Demo Complete ===")

      {:error, reason} ->
        IO.puts("Failed to start pool: #{inspect(reason)}")
    end
  end

  defp demo_progress_streaming do
    IO.puts("1. Progress Streaming")
    IO.puts("   Streaming 10 progress updates...\n")

    result = Snakepit.execute_stream(
      "stream_progress",
      %{steps: 10},
      fn chunk ->
        IO.puts("   Step #{chunk["step"]}/#{chunk["total"]}: #{chunk["progress"]}%")
      end
    )

    case result do
      :ok -> IO.puts("   Complete!\n")
      {:error, e} -> IO.puts("   Error: #{inspect(e)}\n")
    end
  end

  defp demo_data_streaming do
    IO.puts("2. Data Streaming")
    IO.puts("   Streaming Fibonacci sequence...\n")

    result = Snakepit.execute_stream(
      "stream_fibonacci",
      %{count: 15},
      fn chunk ->
        IO.puts("   Fib(#{chunk["index"]}) = #{chunk["value"]}")
      end
    )

    case result do
      :ok -> IO.puts("   Complete!\n")
      {:error, e} -> IO.puts("   Error: #{inspect(e)}\n")
    end
  end
end

ExecuteStreamingToolDemo.run()
```

#### 5.2 Update `examples/run_all.sh`

Add the new example to the list:
```bash
run_example "Execute Streaming Tool Demo" "execute_streaming_tool_demo.exs"
```

#### 5.3 Update `examples/README.md`

Add entry to the examples table:
```markdown
| `execute_streaming_tool_demo.exs` | End-to-end gRPC streaming via BridgeServer |
```

## Verification Checklist

Before considering implementation complete:

### Tests
- [ ] All existing tests pass: `mix test`
- [ ] New streaming tests pass
- [ ] Timeout parsing test passes
- [ ] Binary parameter test passes

### Static Analysis
- [ ] No dialyzer warnings: `mix dialyzer`
- [ ] No credo issues: `mix credo --strict`

### Documentation
- [ ] `guides/streaming.md` updated
- [ ] `README.md` version updated
- [ ] `CHANGELOG.md` entry added
- [ ] `examples/README.md` updated

### Examples
- [ ] New example runs successfully
- [ ] `run_all.sh` includes new example
- [ ] Existing examples still work

### Version
- [ ] `mix.exs` version is `0.8.5`
- [ ] `README.md` references `0.8.5`

## TDD Workflow

For each change:

1. **Write the failing test first**
   ```bash
   mix test test/snakepit/grpc/bridge_server_test.exs --only streaming
   ```

2. **Implement minimum code to pass**

3. **Run the full test suite**
   ```bash
   mix test
   ```

4. **Run static analysis**
   ```bash
   mix dialyzer && mix credo --strict
   ```

5. **Refactor if needed while keeping tests green**

## Common Pitfalls

1. **Don't forget the ToolChunk alias** - The code won't compile without it

2. **Stream return value** - `execute_streaming_tool/2` must return the stream, not `:ok`

3. **Cleanup function** - Always call `cleanup.()` in after block

4. **Final chunk** - Worker may not send one; synthetic final handles this

5. **Error handling** - Use `raise_streaming_rpc_error/2` for proper gRPC status codes

## Success Criteria

The implementation is complete when:

1. `mix test` shows no failures
2. `mix dialyzer` shows no warnings
3. `mix credo --strict` shows no issues
4. Documentation is updated
5. Example runs successfully
6. Version is bumped to 0.8.5
7. CHANGELOG has the entry for 2025-12-30
