# Binary Parameter Decoding Fix

## Overview

Fix binary parameter handling for remote tool execution. The current implementation merges binary parameters as Elixir tuples, which cannot be JSON-encoded for remote forwarding.

## Problem

**Location:** `lib/snakepit/grpc/bridge_server.ex:229-251`

### Current Flow

```elixir
# decode_tool_parameters/2 merges binary params as tuples
defp merge_binary_parameters(decoded, binary_params) when is_map(binary_params) do
  Enum.reduce_while(binary_params, {:ok, decoded}, fn {key, value}, {:ok, acc} ->
    if is_binary(value) do
      {:cont, {:ok, Map.put(acc, normalize_param_key(key), {:binary, value})}}
      #                                                    ^^^^^^^^^^^^^^^^
      #                                                    Tuples not JSON-encodable!
    else
      {:halt, {:error, {:invalid_parameter, normalize_param_key(key), :not_binary}}}
    end
  end)
end
```

### Issue

1. **Local tools:** This is fine - Elixir handlers can work with `{:binary, bytes}` tuples
2. **Remote tools:** This breaks - tuples cannot be JSON-encoded for gRPC forwarding

When forwarding to Python workers, the parameters must be JSON-encodable. The current code path in `execute_tool_handler/4` for remote tools calls `decode_tool_parameters/2`, which embeds binary params as tuples:

```elixir
defp execute_tool_handler(%{type: :remote} = tool, request, session_id, correlation_id) do
  with {:ok, params} <- decode_tool_parameters(request.parameters, request.binary_parameters),
  #                     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  #                     params now contains {:binary, bytes} tuples
       {:ok, channel, cleanup} <- ensure_worker_channel(tool.worker_id) do
    # ...
    forward_tool_to_worker(channel, request, session_id, params, correlation_id)
    #                                                    ^^^^^^
    #                                                    These params get JSON encoded later - FAILS!
  end
end
```

## Solution

### Add New Helper Function

```elixir
@doc """
Decodes parameters for remote tool execution.
Unlike decode_tool_parameters/2, this does NOT merge binary parameters
into the returned map since they need to be forwarded separately.
"""
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

### Update Remote Tool Handler

Update the remote branch of `execute_tool_handler/4`:

```elixir
defp execute_tool_handler(%{type: :remote} = tool, request, session_id, correlation_id) do
  SLog.debug(@log_category, "Executing remote tool",
    tool_name: tool.name,
    worker_id: tool.worker_id
  )

  # Use decode_remote_tool_parameters instead of decode_tool_parameters
  with {:ok, params} <- decode_remote_tool_parameters(request.parameters, request.binary_parameters),
       {:ok, channel, cleanup} <- ensure_worker_channel(tool.worker_id) do
    result =
      try do
        forward_tool_to_worker(channel, request, session_id, params, correlation_id)
      after
        cleanup.()
      end

    case result do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        SLog.error(@log_category, "Failed to execute remote tool",
          tool_name: tool.name,
          worker_id: tool.worker_id,
          reason: reason
        )

        {:error, {:remote_execution_failed, reason}}
    end
  else
    {:error, {:invalid_parameter, _, _}} = error ->
      error

    {:error, reason} ->
      SLog.error(@log_category, "Failed to execute remote tool",
        tool_name: tool.name,
        worker_id: tool.worker_id,
        reason: reason
      )

      {:error, {:remote_execution_failed, reason}}
  end
end
```

### Key Insight

Binary parameters are already passed separately via `request.binary_parameters`. The `forward_tool_to_worker/5` function correctly handles this:

```elixir
defp forward_tool_to_worker(channel, request, session_id, decoded_params, correlation_id) do
  # ...
  worker_request = %ExecuteToolRequest{
    # ...
    binary_parameters: request.binary_parameters  # Passed through unchanged!
  }
  # ...
end
```

So we don't need to merge them into `decoded_params` - they flow through the protobuf message directly.

## Tests to Add

### Test: Remote tool with binary parameters

```elixir
describe "decode_remote_tool_parameters/2" do
  test "decodes JSON parameters without merging binary params" do
    json_params = %{
      "name" => %Google.Protobuf.Any{
        type_url: "type.googleapis.com/google.protobuf.StringValue",
        value: Jason.encode!("test_value")
      }
    }
    binary_params = %{"data" => <<1, 2, 3, 4>>}

    {:ok, decoded} = BridgeServer.decode_remote_tool_parameters(json_params, binary_params)

    # JSON params decoded
    assert decoded["name"] == "test_value"

    # Binary params NOT merged (unlike local tool handling)
    refute Map.has_key?(decoded, "data")
  end

  test "validates binary parameters are actually binaries" do
    json_params = %{}
    binary_params = %{"invalid" => 12345}  # Not a binary!

    result = BridgeServer.decode_remote_tool_parameters(json_params, binary_params)

    assert {:error, {:invalid_parameter, "invalid", :not_binary}} = result
  end

  test "handles nil binary_params" do
    json_params = %{}
    {:ok, decoded} = BridgeServer.decode_remote_tool_parameters(json_params, nil)
    assert decoded == %{}
  end

  test "handles empty binary_params" do
    json_params = %{}
    {:ok, decoded} = BridgeServer.decode_remote_tool_parameters(json_params, %{})
    assert decoded == %{}
  end
end
```

### Test: Remote execution with binary params

```elixir
test "remote tool execution forwards binary parameters correctly", %{session_id: session_id} do
  ensure_tool_registry_started()
  ensure_started(Snakepit.Pool.Registry)
  {:ok, _session} = SessionStore.create_session(session_id)

  worker_id = "binary_remote_#{System.unique_integer([:positive])}"
  {:ok, _worker_pid} = start_supervised({ChannelWorker, {self(), worker_id}})

  :ok = ToolRegistry.register_python_tool(session_id, "process_binary", worker_id, %{})

  binary_payload = :crypto.strong_rand_bytes(1024)

  request = %ExecuteToolRequest{
    session_id: session_id,
    tool_name: "process_binary",
    parameters: %{
      "format" => %Google.Protobuf.Any{
        type_url: "type.googleapis.com/google.protobuf.StringValue",
        value: Jason.encode!("png")
      }
    },
    binary_parameters: %{"image" => binary_payload},
    metadata: %{}
  }

  response = BridgeServer.execute_tool(request, nil)
  assert %ExecuteToolResponse{success: true} = response

  # Verify the mock client received the call
  assert_receive {:grpc_client_execute_tool, ^session_id, "process_binary", decoded_params, opts}, 1_000

  # JSON params should be decoded
  assert decoded_params["format"] == "png"

  # Binary params should be forwarded separately (not merged into decoded_params)
  refute Map.has_key?(decoded_params, "image")
  assert opts[:binary_parameters] == %{"image" => binary_payload}
end
```

## Comparison: Local vs Remote

| Aspect | Local Tools | Remote Tools |
|--------|-------------|--------------|
| Binary params handling | Merged as `{:binary, bytes}` | Passed separately via protobuf |
| JSON encoding needed | No | Yes (for params map) |
| Handler receives | `%{"data" => {:binary, <<...>>}}` | `%{}` with binary in `request.binary_parameters` |
| Function | `decode_tool_parameters/2` | `decode_remote_tool_parameters/2` |

## Why This Matters for Streaming

Streaming tools are always remote. If binary parameters are merged as tuples, the streaming request will fail when trying to JSON-encode parameters for the worker.

This fix is a prerequisite for reliable streaming tool execution with binary data (e.g., streaming image processing, audio processing, etc.).
