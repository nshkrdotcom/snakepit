# Timeout Parsing Fix

## Overview

Fix a precedence bug in `tool_call_options/1` that can return incorrect types.

## Problem

**Location:** `lib/snakepit/grpc/bridge_server.ex:366-375`

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

### Issue Analysis

Due to operator precedence, this code is parsed as:

```elixir
(Map.get("timeout_ms") || (Map.get(:timeout_ms) |> parse_timeout_ms() |> case ...))
```

**Problematic scenarios:**

1. If `metadata["timeout_ms"]` is a string like `"5000"`:
   - Returns `"5000"` (a string) instead of `[timeout: 5000]`
   - Later `Keyword.put/3` fails with `** (ArgumentError)`

2. If `metadata["timeout_ms"]` is `nil` but `:timeout_ms` exists:
   - Works correctly (goes through `parse_timeout_ms`)

3. If neither key exists:
   - Returns `[]` (correct)

### Root Cause

The `||` operator has lower precedence than `|>`, so the fallback path (`Map.get(:timeout_ms) |> ...`) is only taken when the first `Map.get` returns `nil`.

When `Map.get("timeout_ms")` returns a truthy value (like a string), it short-circuits and returns that value directly without going through `parse_timeout_ms`.

## Solution

### Fixed Implementation

```elixir
defp tool_call_options(metadata) when is_map(metadata) do
  value = Map.get(metadata, "timeout_ms") || Map.get(metadata, :timeout_ms)

  case parse_timeout_ms(value) do
    {:ok, timeout} -> [timeout: timeout]
    :error -> []
  end
end
```

### Why This Works

1. First, resolve the value from either string or atom key
2. Then, always pass through `parse_timeout_ms/1`
3. Return keyword list based on parsing result

## Tests to Add

### Test: String timeout values are parsed correctly

```elixir
describe "tool_call_options/1" do
  test "parses string timeout_ms from string key" do
    metadata = %{"timeout_ms" => "5000"}
    assert tool_call_options(metadata) == [timeout: 5000]
  end

  test "parses integer timeout_ms from string key" do
    metadata = %{"timeout_ms" => 5000}
    assert tool_call_options(metadata) == [timeout: 5000]
  end

  test "parses timeout_ms from atom key" do
    metadata = %{timeout_ms: 5000}
    assert tool_call_options(metadata) == [timeout: 5000]
  end

  test "prefers string key over atom key" do
    metadata = %{"timeout_ms" => "3000", timeout_ms: 5000}
    assert tool_call_options(metadata) == [timeout: 3000]
  end

  test "returns empty list for invalid timeout" do
    metadata = %{"timeout_ms" => "invalid"}
    assert tool_call_options(metadata) == []
  end

  test "returns empty list for zero timeout" do
    metadata = %{"timeout_ms" => 0}
    assert tool_call_options(metadata) == []
  end

  test "returns empty list for negative timeout" do
    metadata = %{"timeout_ms" => -100}
    assert tool_call_options(metadata) == []
  end

  test "returns empty list when no timeout key exists" do
    metadata = %{"other_key" => "value"}
    assert tool_call_options(metadata) == []
  end

  test "returns empty list for empty metadata" do
    assert tool_call_options(%{}) == []
  end
end
```

### Note on Test Access

Since `tool_call_options/1` is a private function, tests should either:

1. Test indirectly through `execute_tool/2` with different metadata values
2. Use `@compile {:no_warn_undefined, ...}` and call via `:erlang.apply/3`
3. Extract to a separate module for testability

**Recommended approach:** Test indirectly by verifying that tool execution with string timeout metadata works correctly:

```elixir
test "execute_tool respects string timeout_ms in metadata", %{session_id: session_id} do
  ensure_tool_registry_started()
  {:ok, _session} = SessionStore.create_session(session_id)

  worker_id = "timeout_test_#{System.unique_integer([:positive])}"
  {:ok, _worker_pid} = start_supervised({ChannelWorker, {self(), worker_id}})

  :ok = ToolRegistry.register_python_tool(session_id, "test_tool", worker_id, %{})

  request = %ExecuteToolRequest{
    session_id: session_id,
    tool_name: "test_tool",
    parameters: %{},
    metadata: %{"timeout_ms" => "5000"}  # String value
  }

  # Should not crash - previously would fail with ArgumentError
  response = BridgeServer.execute_tool(request, nil)

  # The mock client should receive the call successfully
  assert_receive {:grpc_client_execute_tool, ^session_id, "test_tool", %{}, opts}, 1_000

  # Verify timeout was parsed correctly
  assert opts[:timeout] == 5000
end
```

## Impact Assessment

### Before Fix

```elixir
metadata = %{"timeout_ms" => "5000"}
tool_call_options(metadata)
# => "5000"  (BUG: returns string)

# Later in forward_tool_to_worker:
opts = tool_call_options(metadata)
     |> Keyword.put(:binary_parameters, %{})
# => ** (ArgumentError) expected a keyword list, but an entry in the list is not a two-element tuple with an atom as its first element
```

### After Fix

```elixir
metadata = %{"timeout_ms" => "5000"}
tool_call_options(metadata)
# => [timeout: 5000]  (CORRECT: returns keyword list)

# Later operations work correctly
opts = tool_call_options(metadata)
     |> Keyword.put(:binary_parameters, %{})
# => [timeout: 5000, binary_parameters: %{}]
```

## Migration Notes

This is a bug fix with no breaking changes to the public API. The fix makes the behavior match what users would reasonably expect.
