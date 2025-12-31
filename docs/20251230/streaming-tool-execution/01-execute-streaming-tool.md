# ExecuteStreamingTool Implementation

## Overview

This document details the implementation of `execute_streaming_tool/2` in `Snakepit.GRPC.BridgeServer`.

## Current Implementation

**Location:** `lib/snakepit/grpc/bridge_server.ex:473-488`

```elixir
def execute_streaming_tool(%ExecuteToolRequest{} = request, _stream) do
  hint =
    "Streaming execution is not enabled for tool #{request.tool_name}. " <>
      "Enable streaming support on the adapter (set supports_streaming: true) or use execute_tool instead. " <>
      "See docs/20251026/SNAKEPIT_STREAMING_PROMPT.md for enablement steps."

  SLog.warning(
    @log_category,
    "Streaming request received but streaming support is disabled. Returning UNIMPLEMENTED.",
    tool_name: request.tool_name
  )

  raise GRPC.RPCError,
    status: :unimplemented,
    message: hint
end
```

## New Implementation

### Required Alias Addition

Add `ToolChunk` to the alias list near the top of the file:

```elixir
alias Snakepit.Bridge.{
  # ... existing aliases ...
  ToolChunk
}
```

### Main Function

Replace the current implementation with:

```elixir
def execute_streaming_tool(%ExecuteToolRequest{} = request, stream) do
  SLog.info(@log_category, "ExecuteStreamingTool",
    tool_name: request.tool_name,
    session_id: request.session_id
  )

  start_time_ms = System.monotonic_time(:millisecond)
  correlation_id = resolve_request_correlation_id(request, stream)
  request = ensure_request_correlation(request, correlation_id)

  with {:ok, _session} <- SessionStore.get_session(request.session_id),
       {:ok, tool} <- ToolRegistry.get_tool(request.session_id, request.tool_name),
       :ok <- ensure_streaming_supported(tool, request) do
    case execute_remote_stream(tool, request, stream, correlation_id, start_time_ms) do
      :ok ->
        stream

      {:error, reason} ->
        raise_streaming_rpc_error(request, reason)
    end
  else
    {:error, :not_found} ->
      raise GRPC.RPCError,
        status: :not_found,
        message: "Session not found: #{request.session_id}"

    {:error, message} when is_binary(message) ->
      raise GRPC.RPCError,
        status: :not_found,
        message: message

    {:error, {:invalid_parameter, _key, _reason} = invalid} ->
      raise GRPC.RPCError,
        status: :invalid_argument,
        message: format_error(invalid)

    {:error, reason} ->
      raise GRPC.RPCError,
        status: :internal,
        message: format_error(reason)
  end
end
```

### Helper Functions

#### Streaming Support Validation

```elixir
defp ensure_streaming_supported(%{type: :remote} = tool, _request) do
  if tool_supports_streaming?(tool) do
    :ok
  else
    {:error, {:streaming_not_supported, tool.name}}
  end
end

defp ensure_streaming_supported(_tool, _request) do
  {:error, {:streaming_not_supported, :local_tool}}
end

defp tool_supports_streaming?(%{metadata: metadata}) when is_map(metadata) do
  value = Map.get(metadata, "supports_streaming") || Map.get(metadata, :supports_streaming)

  case value do
    true -> true
    "true" -> true
    "1" -> true
    1 -> true
    _ -> false
  end
end

defp tool_supports_streaming?(_), do: false
```

#### Remote Stream Execution

```elixir
defp execute_remote_stream(%{type: :remote} = tool, %ExecuteToolRequest{} = request, stream, correlation_id, start_time_ms) do
  with {:ok, decoded_params} <- decode_remote_tool_parameters(request.parameters, request.binary_parameters),
       {:ok, channel, cleanup} <- ensure_worker_channel(tool.worker_id),
       {:ok, worker_stream} <- forward_streaming_tool_to_worker(channel, request, decoded_params, correlation_id) do
    try do
      forward_worker_stream(worker_stream, stream, start_time_ms, tool)
    after
      cleanup.()
    end
  end
end
```

#### Forward to Worker

```elixir
defp forward_streaming_tool_to_worker(channel, %ExecuteToolRequest{} = request, decoded_params, correlation_id) do
  worker_metadata = ensure_metadata_correlation(request.metadata, correlation_id)
  binary_params = request.binary_parameters || %{}

  opts =
    worker_metadata
    |> tool_call_options()
    |> Keyword.put(:binary_parameters, binary_params)
    |> Keyword.put(:correlation_id, correlation_id)

  channel
  |> GRPCClient.execute_streaming_tool(request.session_id, request.tool_name, decoded_params, opts)
  |> normalize_stream_response()
end

defp normalize_stream_response({:ok, stream, _headers}), do: {:ok, stream}
defp normalize_stream_response({:ok, stream}), do: {:ok, stream}
defp normalize_stream_response({:error, reason}), do: {:error, reason}
defp normalize_stream_response(other), do: {:error, {:unexpected_stream_response, other}}
```

#### Stream Forwarding

```elixir
defp forward_worker_stream(worker_stream, grpc_stream, start_time_ms, tool) do
  acc0 = %{sent: 0, final_seen?: false}

  result =
    Enum.reduce_while(worker_stream, acc0, fn item, acc ->
      case normalize_stream_item(item) do
        {:ok, %ToolChunk{} = chunk} ->
          final_seen? = acc.final_seen? or chunk.is_final
          chunk = maybe_decorate_final_chunk(chunk, start_time_ms, tool)

          case GRPC.Stream.send_reply(grpc_stream, chunk) do
            :ok ->
              {:cont, %{acc | sent: acc.sent + 1, final_seen?: final_seen?}}

            {:error, reason} ->
              {:halt, {:error, {:stream_send_failed, reason}}}
          end

        :skip ->
          {:cont, acc}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)

  case result do
    {:error, reason} ->
      {:error, reason}

    %{final_seen?: true} ->
      :ok

    %{final_seen?: false} = acc ->
      send_synthetic_final_chunk(grpc_stream, start_time_ms, tool, acc.sent)
  end
end

defp normalize_stream_item({:ok, %ToolChunk{} = chunk}), do: {:ok, chunk}
defp normalize_stream_item(%ToolChunk{} = chunk), do: {:ok, chunk}
defp normalize_stream_item({:trailers, _trailers}), do: :skip
defp normalize_stream_item({:error, reason}), do: {:error, reason}
defp normalize_stream_item(other), do: {:error, {:unexpected_stream_item, other}}
```

#### Chunk Decoration and Synthetic Final

```elixir
defp maybe_decorate_final_chunk(%ToolChunk{is_final: true} = chunk, start_time_ms, tool) do
  exec_ms = System.monotonic_time(:millisecond) - start_time_ms

  metadata =
    (chunk.metadata || %{})
    |> Map.put_new("execution_time_ms", to_string(exec_ms))
    |> Map.put_new("tool_type", to_string(tool.type))
    |> Map.put_new("worker_id", to_string(tool.worker_id || ""))

  %{chunk | metadata: metadata}
end

defp maybe_decorate_final_chunk(chunk, _start_time_ms, _tool), do: chunk

defp send_synthetic_final_chunk(grpc_stream, start_time_ms, tool, sent_count) do
  exec_ms = System.monotonic_time(:millisecond) - start_time_ms

  chunk = %ToolChunk{
    chunk_id: "sp-final-#{:erlang.unique_integer([:positive, :monotonic])}",
    data: <<>>,
    is_final: true,
    metadata: %{
      "synthetic_final" => "true",
      "execution_time_ms" => to_string(exec_ms),
      "tool_type" => to_string(tool.type),
      "chunks_sent" => to_string(sent_count)
    }
  }

  case GRPC.Stream.send_reply(grpc_stream, chunk) do
    :ok -> :ok
    {:error, reason} -> {:error, {:stream_send_failed, reason}}
  end
end
```

#### Error Handling

```elixir
defp raise_streaming_rpc_error(%ExecuteToolRequest{} = request, {:streaming_not_supported, _}) do
  hint =
    "Streaming execution is not enabled for tool #{request.tool_name}. " <>
      "Enable streaming support on the adapter (supports_streaming: true) or use ExecuteTool instead."

  raise GRPC.RPCError, status: :unimplemented, message: hint
end

defp raise_streaming_rpc_error(_request, {:stream_send_failed, reason}) do
  raise GRPC.RPCError, status: :unavailable, message: "Client stream closed: #{inspect(reason)}"
end

defp raise_streaming_rpc_error(_request, reason) do
  raise GRPC.RPCError, status: :internal, message: format_error(reason)
end
```

## Tests to Add

### Test: Streaming requires remote tool

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

  test "raises UNIMPLEMENTED for remote tools without streaming support", %{session_id: session_id} do
    ensure_tool_registry_started()
    ensure_started(Snakepit.Pool.Registry)
    {:ok, _session} = SessionStore.create_session(session_id)

    worker_id = "streaming_test_#{System.unique_integer([:positive])}"
    {:ok, _worker_pid} = start_supervised({ChannelWorker, {self(), worker_id}})

    :ok = ToolRegistry.register_python_tool(
      session_id,
      "non_streaming_remote",
      worker_id,
      %{"supports_streaming" => "false"}
    )

    request = %ExecuteToolRequest{
      session_id: session_id,
      tool_name: "non_streaming_remote",
      parameters: %{},
      metadata: %{}
    }

    error = assert_raise GRPC.RPCError, fn ->
      BridgeServer.execute_streaming_tool(request, nil)
    end

    assert error.status == Status.unimplemented()
  end

  test "raises NOT_FOUND for non-existent session", %{session_id: _session_id} do
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
end
```

### Test: Streaming with mock worker

```elixir
test "forwards streaming request to worker and relays chunks", %{session_id: session_id} do
  ensure_tool_registry_started()
  ensure_started(Snakepit.Pool.Registry)
  {:ok, _session} = SessionStore.create_session(session_id)

  worker_id = "streaming_worker_#{System.unique_integer([:positive])}"
  {:ok, _worker_pid} = start_supervised({ChannelWorker, {self(), worker_id}})

  :ok = ToolRegistry.register_python_tool(
    session_id,
    "streaming_tool",
    worker_id,
    %{"supports_streaming" => "true"}
  )

  request = %ExecuteToolRequest{
    session_id: session_id,
    tool_name: "streaming_tool",
    parameters: %{},
    metadata: %{}
  }

  # Mock stream that collects sent replies
  mock_stream = %{
    sent_replies: [],
    __struct__: GRPC.Server.Stream
  }

  # Execute streaming - the mock client will be called
  result = BridgeServer.execute_streaming_tool(request, mock_stream)

  assert result == mock_stream

  # Verify the mock client was called
  assert_receive {:grpc_client_execute_streaming_tool, ^session_id, "streaming_tool", %{}, _opts}, 1_000
end
```

## Error Cases to Handle

| Scenario | Expected Error | Status Code |
|----------|----------------|-------------|
| Session not found | "Session not found: {id}" | `NOT_FOUND` |
| Tool not found | "Tool {name} not found for session {id}" | `NOT_FOUND` |
| Local tool | "Streaming not enabled..." | `UNIMPLEMENTED` |
| Remote without streaming | "Streaming not enabled..." | `UNIMPLEMENTED` |
| Worker unavailable | "Worker not found: {id}" | `UNAVAILABLE` |
| Stream send failed | "Client stream closed: {reason}" | `UNAVAILABLE` |
| Invalid parameters | "Invalid parameter {key}: {reason}" | `INVALID_ARGUMENT` |

## Integration Points

This implementation depends on:

1. `decode_remote_tool_parameters/2` - See [03-binary-parameter-fix.md](./03-binary-parameter-fix.md)
2. `tool_call_options/1` fix - See [02-timeout-parsing-fix.md](./02-timeout-parsing-fix.md)
3. `GRPCClient.execute_streaming_tool/5` - Already exists in `lib/snakepit/grpc/client.ex`
4. `ToolChunk` protobuf message - Already exists in generated code
