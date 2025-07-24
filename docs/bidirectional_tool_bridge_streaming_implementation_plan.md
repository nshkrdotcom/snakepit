# Bidirectional Tool Bridge - Streaming Implementation Plan

## Executive Summary

This document outlines the implementation plan for adding streaming capabilities to the bidirectional tool bridge, enabling real-time progress updates, chunked data processing, and long-running tool executions across Elixir and Python.

## Goals and Requirements

### Primary Goals
1. **Real-time Progress Updates**: Tools can emit progress during execution
2. **Chunked Data Processing**: Handle large datasets without memory constraints
3. **Cancellable Operations**: Gracefully stop long-running tools
4. **Bidirectional Streaming**: Both Elixir and Python can stream to each other
5. **Backward Compatibility**: Non-streaming tools continue to work unchanged

### Key Requirements
- Zero configuration for basic streaming
- Type-safe streaming protocols
- Automatic backpressure handling
- Error recovery and partial results
- Session-aware streaming context

## Architecture Design

### Streaming Protocol

```protobuf
// New streaming RPCs to add to snakepit_bridge.proto
service BridgeService {
  // Existing RPCs...
  
  // Streaming tool execution
  rpc ExecuteToolStream(ExecuteToolStreamRequest) returns (stream ExecuteToolStreamResponse);
  rpc ExecuteElixirToolStream(ExecuteElixirToolStreamRequest) returns (stream ExecuteElixirToolStreamResponse);
  
  // Bidirectional streaming for interactive tools
  rpc ExecuteToolBidirectional(stream ExecuteToolBidirectionalRequest) returns (stream ExecuteToolBidirectionalResponse);
}

message ExecuteToolStreamRequest {
  string session_id = 1;
  string tool_name = 2;
  map<string, google.protobuf.Any> parameters = 3;
  StreamingConfig config = 4;
}

message StreamingConfig {
  int32 chunk_size = 1;              // Max items per chunk
  int32 buffer_size = 2;             // Backpressure buffer
  bool partial_results_ok = 3;       // Allow partial on error
  int32 heartbeat_interval_ms = 4;   // Keep-alive interval
}

message ExecuteToolStreamResponse {
  oneof content {
    ProgressUpdate progress = 1;
    ChunkData chunk = 2;
    ToolResult result = 3;
    ErrorInfo error = 4;
    StreamControl control = 5;
  }
}

message ProgressUpdate {
  float percent = 1;
  string message = 2;
  map<string, google.protobuf.Any> metadata = 3;
  int64 items_processed = 4;
  int64 total_items = 5;
}

message ChunkData {
  int32 sequence_number = 1;
  google.protobuf.Any data = 2;
  bool is_last = 3;
  map<string, string> metadata = 4;
}

message StreamControl {
  enum Type {
    PAUSE = 0;
    RESUME = 1;
    CANCEL = 2;
    HEARTBEAT = 3;
  }
  Type type = 1;
  string reason = 2;
}
```

### Component Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Streaming Architecture                   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Elixir Side:                                               │
│  ┌─────────────────────────────────────────────────────────┐│
│  │  StreamingToolRegistry (extends ToolRegistry)           ││
│  │    - register_streaming_tool/5                          ││
│  │    - execute_streaming_tool/4                           ││
│  │    - cancel_stream/2                                    ││
│  └─────────────────────────────────────────────────────────┘│
│                                                             │
│  ┌─────────────────────────────────────────────────────────┐│
│  │  BridgeServer Streaming Handlers                        ││
│  │    - execute_tool_stream/2                              ││
│  │    - execute_elixir_tool_stream/2                       ││
│  │    - handle_stream_control/3                            ││
│  └─────────────────────────────────────────────────────────┘│
│                                                             │
│  Python Side:                                               │
│  ┌─────────────────────────────────────────────────────────┐│
│  │  StreamingContext (extends SessionContext)              ││
│  │    - stream_elixir_tool()                               ││
│  │    - cancel_stream()                                    ││
│  │    - handle_backpressure()                              ││
│  └─────────────────────────────────────────────────────────┘│
│                                                             │
│  ┌─────────────────────────────────────────────────────────┐│
│  │  @streaming_tool decorator                              ││
│  │    - Marks Python functions as streaming-capable        ││
│  │    - Provides yield interface for chunks                ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

## Implementation Phases

### Phase 1: Foundation (Week 1)

#### 1.1 Protocol Buffer Extensions
```bash
# Add streaming messages to snakepit_bridge.proto
# Regenerate Python and Elixir code
make proto-python
make proto-elixir
```

#### 1.2 Elixir Streaming Registry
```elixir
defmodule Snakepit.Bridge.StreamingToolRegistry do
  use GenServer
  
  defstruct [:ets_table, :active_streams]
  
  def register_streaming_tool(session_id, name, handler, metadata, stream_config) do
    # Validate handler supports streaming (arity/2 with stream parameter)
    # Store with streaming metadata
  end
  
  def execute_streaming_tool(session_id, tool_name, params, stream_handler) do
    # Look up tool
    # Create stream process
    # Execute with backpressure control
  end
end
```

#### 1.3 Stream Process Manager
```elixir
defmodule Snakepit.Bridge.StreamProcess do
  use GenServer
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end
  
  def init(opts) do
    state = %{
      session_id: opts.session_id,
      tool_name: opts.tool_name,
      handler: opts.handler,
      client_pid: opts.client_pid,
      buffer: :queue.new(),
      status: :active,
      stats: %{chunks_sent: 0, bytes_sent: 0}
    }
    {:ok, state}
  end
  
  def handle_cast({:chunk, data}, state) do
    # Buffer management with backpressure
  end
  
  def handle_info(:send_chunk, state) do
    # Send buffered chunks to client
  end
end
```

### Phase 2: Python Streaming Support (Week 2)

#### 2.1 Streaming Decorator
```python
from snakepit_bridge.streaming import streaming_tool, StreamContext

class MLAdapter(BaseAdapter):
    @streaming_tool(
        description="Process dataset in chunks",
        chunk_size=1000,
        supports_cancel=True
    )
    async def process_large_dataset(self, ctx: StreamContext, file_path: str):
        total_rows = count_rows(file_path)
        
        async for chunk in read_csv_chunks(file_path, chunk_size=1000):
            # Process chunk
            processed = transform_chunk(chunk)
            
            # Check for cancellation
            if ctx.is_cancelled:
                await ctx.emit_control("CANCEL", "User requested cancellation")
                break
            
            # Emit progress
            await ctx.emit_progress(
                percent=(ctx.chunks_sent * 1000) / total_rows * 100,
                message=f"Processing chunk {ctx.chunks_sent + 1}",
                items_processed=ctx.chunks_sent * 1000,
                total_items=total_rows
            )
            
            # Yield chunk
            yield processed
            
        # Final result
        return {"total_processed": ctx.chunks_sent * 1000}
```

#### 2.2 Streaming Context
```python
class StreamContext:
    def __init__(self, session_context, request_id):
        self.session = session_context
        self.request_id = request_id
        self.chunks_sent = 0
        self.is_cancelled = False
        self._buffer = asyncio.Queue(maxsize=10)
        
    async def emit_progress(self, percent, message, **metadata):
        """Emit progress update to client."""
        msg = ProgressUpdate(
            percent=percent,
            message=message,
            metadata=self._encode_metadata(metadata)
        )
        await self._send_response(progress=msg)
        
    async def emit_chunk(self, data, is_last=False):
        """Emit data chunk with backpressure."""
        chunk = ChunkData(
            sequence_number=self.chunks_sent,
            data=self._encode_any(data),
            is_last=is_last
        )
        await self._buffer.put(chunk)
        self.chunks_sent += 1
        
    async def check_cancellation(self):
        """Check if stream was cancelled."""
        # Poll for control messages
        pass
```

#### 2.3 Client-Side Streaming
```python
# Using streaming tools from Python
async def example_streaming_usage():
    ctx = SessionContext(stub, session_id)
    
    # Async iteration over stream
    async for chunk in ctx.stream_elixir_tool("process_images", 
                                              images=image_list,
                                              batch_size=10):
        if chunk.HasField("progress"):
            print(f"Progress: {chunk.progress.percent}%")
        elif chunk.HasField("chunk"):
            # Process chunk data
            results = decode_chunk(chunk.chunk)
            save_results(results)
        elif chunk.HasField("error"):
            print(f"Error: {chunk.error.message}")
            break
    
    # With cancellation support
    stream = ctx.stream_elixir_tool("long_running_analysis", data=dataset)
    try:
        async for chunk in stream:
            process_chunk(chunk)
            if should_stop():
                await stream.cancel("User requested stop")
                break
    finally:
        await stream.close()
```

### Phase 3: Elixir Streaming Implementation (Week 3)

#### 3.1 BridgeServer Streaming Handlers
```elixir
defmodule Snakepit.GRPC.BridgeServer do
  # Existing code...
  
  def execute_tool_stream(request, stream) do
    Logger.info("Starting streaming execution: #{request.tool_name}")
    
    # Create stream process
    {:ok, stream_pid} = StreamProcess.start_link(%{
      session_id: request.session_id,
      tool_name: request.tool_name,
      parameters: decode_parameters(request.parameters),
      config: request.config
    })
    
    # Monitor stream process
    ref = Process.monitor(stream_pid)
    
    # Stream responses
    stream_responses(stream_pid, stream, ref)
  end
  
  defp stream_responses(stream_pid, grpc_stream, monitor_ref) do
    receive do
      {:stream_response, ^stream_pid, response} ->
        # Send to gRPC stream
        GRPC.Server.send_reply(grpc_stream, response)
        stream_responses(stream_pid, grpc_stream, monitor_ref)
        
      {:stream_complete, ^stream_pid, final_result} ->
        # Send final result
        GRPC.Server.send_reply(grpc_stream, %ExecuteToolStreamResponse{
          content: {:result, encode_result(final_result)}
        })
        
      {:DOWN, ^monitor_ref, :process, ^stream_pid, reason} ->
        # Handle stream process crash
        GRPC.Server.send_reply(grpc_stream, %ExecuteToolStreamResponse{
          content: {:error, %ErrorInfo{
            message: "Stream process terminated: #{inspect(reason)}"
          }}
        })
        
      {:grpc_cancel, ^grpc_stream} ->
        # Client cancelled the stream
        StreamProcess.cancel(stream_pid)
    end
  end
end
```

#### 3.2 Elixir Streaming Tools
```elixir
defmodule MyApp.StreamingTools do
  def process_batch_stream(params, stream) do
    items = params["items"]
    total = length(items)
    
    items
    |> Enum.with_index(1)
    |> Enum.each(fn {item, index} ->
      # Process item
      result = process_item(item)
      
      # Send progress
      stream.(:progress, %{
        percent: (index / total) * 100,
        message: "Processing item #{index} of #{total}",
        current_item: item
      })
      
      # Send chunk
      stream.(:chunk, %{
        data: result,
        sequence: index,
        is_last: index == total
      })
      
      # Check for cancellation
      if stream.(:check_cancel) do
        stream.(:cancelled, "Operation cancelled")
        :halt
      end
    end)
    
    # Return final result
    {:ok, %{processed: total, status: "complete"}}
  end
end

# Registration
ToolRegistry.register_streaming_tool(
  session_id,
  "process_batch_stream",
  &MyApp.StreamingTools.process_batch_stream/2,
  %{
    description: "Process items in batches with progress",
    supports_streaming: true,
    supports_cancellation: true,
    estimated_duration_ms: 60_000
  }
)
```

### Phase 4: Advanced Features (Week 4)

#### 4.1 Bidirectional Streaming
```elixir
# Elixir side - interactive tool
def interactive_analysis(stream) do
  # Initial analysis
  stream.(:send, %{status: "ready", awaiting: "input"})
  
  # Interactive loop
  loop = fn loop ->
    receive do
      {:client_input, data} ->
        # Process input
        result = analyze(data)
        stream.(:send, result)
        
        if result.complete do
          {:ok, result}
        else
          loop.(loop)
        end
        
      {:cancel} ->
        {:cancelled, "User cancelled"}
    end
  end
  
  loop.(loop)
end
```

```python
# Python side - bidirectional client
async def interactive_session():
    ctx = SessionContext(stub, session_id)
    
    stream = await ctx.bidirectional_stream("interactive_analysis")
    
    # Send initial data
    await stream.send({"query": "analyze this dataset"})
    
    # Interactive loop
    async for response in stream:
        if response.awaiting == "input":
            user_input = await get_user_input()
            await stream.send({"input": user_input})
        else:
            display_results(response)
            
        if response.complete:
            break
```

#### 4.2 Stream Composition
```python
# Compose multiple streaming tools
async def composed_pipeline(ctx, input_data):
    # First stage: preprocessing
    preprocessed = ctx.stream_elixir_tool("preprocess_stream", data=input_data)
    
    # Second stage: analysis (using first stage output)
    analyzed = ctx.stream_elixir_tool("analyze_stream", 
        input_stream=preprocessed,
        model="advanced"
    )
    
    # Third stage: post-processing
    async for chunk in analyzed:
        if chunk.HasField("chunk"):
            processed = await post_process(chunk.chunk.data)
            yield processed
```

#### 4.3 Error Recovery
```elixir
defmodule Snakepit.Bridge.StreamRecovery do
  def with_recovery(stream_fn, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, 3)
    checkpoint_interval = Keyword.get(opts, :checkpoint_interval, 100)
    
    fn params, stream ->
      state = %{
        last_checkpoint: 0,
        retry_count: 0,
        partial_results: []
      }
      
      try do
        stream_fn.(params, wrapped_stream(stream, state))
      catch
        :error, reason when state.retry_count < max_retries ->
          # Retry from last checkpoint
          stream.(:progress, %{
            message: "Recovering from error, retry #{state.retry_count + 1}",
            checkpoint: state.last_checkpoint
          })
          
          # Resume from checkpoint
          resume_params = Map.put(params, :resume_from, state.last_checkpoint)
          with_recovery(stream_fn, opts).(resume_params, stream)
      end
    end
  end
end
```

## Performance Considerations

### 1. Buffering Strategy
```elixir
defmodule Snakepit.Bridge.StreamBuffer do
  @default_size 100
  @high_watermark 80
  @low_watermark 20
  
  def new(opts \\ []) do
    %{
      buffer: :queue.new(),
      size: 0,
      max_size: Keyword.get(opts, :size, @default_size),
      paused: false
    }
  end
  
  def put(buffer, item) do
    if buffer.size >= buffer.max_size do
      {:error, :buffer_full}
    else
      updated = %{
        buffer | 
        buffer: :queue.in(item, buffer.buffer),
        size: buffer.size + 1
      }
      
      # Check high watermark
      if updated.size >= @high_watermark * updated.max_size / 100 do
        {:ok, updated, :pause_producer}
      else
        {:ok, updated}
      end
    end
  end
end
```

### 2. Memory Management
```python
class ChunkedFileProcessor:
    def __init__(self, chunk_size=1024*1024):  # 1MB chunks
        self.chunk_size = chunk_size
        
    async def process_file_stream(self, ctx: StreamContext, file_path: str):
        file_size = os.path.getsize(file_path)
        chunks_total = math.ceil(file_size / self.chunk_size)
        
        with open(file_path, 'rb') as f:
            for i in range(chunks_total):
                # Read chunk
                chunk = f.read(self.chunk_size)
                
                # Process without loading entire file
                processed = await self.process_chunk(chunk)
                
                # Stream result
                await ctx.emit_chunk(processed, is_last=(i == chunks_total - 1))
                
                # Allow GC to clean up
                del chunk
                
                # Progress update
                await ctx.emit_progress(
                    percent=(i + 1) / chunks_total * 100,
                    message=f"Processed {i + 1}/{chunks_total} chunks"
                )
```

### 3. Network Optimization
```protobuf
// Compression for large chunks
message StreamingConfig {
  // Existing fields...
  CompressionType compression = 5;
  int32 max_chunk_size_bytes = 6;
}

enum CompressionType {
  NONE = 0;
  GZIP = 1;
  SNAPPY = 2;
  LZ4 = 3;
}
```

## Testing Strategy

### 1. Unit Tests
```elixir
defmodule StreamingToolTest do
  use ExUnit.Case
  
  test "streaming tool emits progress updates" do
    {:ok, stream} = TestStream.new()
    
    result = StreamingTools.process_batch_stream(
      %{"items" => [1, 2, 3]},
      stream
    )
    
    assert {:ok, %{processed: 3}} = result
    
    # Verify progress updates
    assert [
      {:progress, %{percent: 33.33}},
      {:chunk, %{sequence: 1}},
      {:progress, %{percent: 66.66}},
      {:chunk, %{sequence: 2}},
      {:progress, %{percent: 100.0}},
      {:chunk, %{sequence: 3, is_last: true}}
    ] = TestStream.get_events(stream)
  end
  
  test "streaming handles cancellation" do
    {:ok, stream} = TestStream.new(cancel_after: 2)
    
    result = StreamingTools.process_batch_stream(
      %{"items" => [1, 2, 3, 4, 5]},
      stream
    )
    
    assert {:cancelled, _} = result
    assert length(TestStream.get_chunks(stream)) == 2
  end
end
```

### 2. Integration Tests
```python
import pytest
from snakepit_bridge.testing import StreamingTestCase

class TestStreamingIntegration(StreamingTestCase):
    @pytest.mark.asyncio
    async def test_python_streams_to_elixir(self):
        ctx = self.create_test_context()
        
        chunks = []
        async for chunk in ctx.stream_elixir_tool("echo_stream", 
                                                  data=["a", "b", "c"]):
            if chunk.HasField("chunk"):
                chunks.append(chunk.chunk.data)
        
        assert chunks == ["a", "b", "c"]
    
    @pytest.mark.asyncio
    async def test_cancellation_propagates(self):
        ctx = self.create_test_context()
        
        stream = ctx.stream_elixir_tool("infinite_stream")
        chunks_received = 0
        
        async for chunk in stream:
            chunks_received += 1
            if chunks_received >= 5:
                await stream.cancel("Test cancellation")
                break
        
        assert chunks_received == 5
        assert stream.is_cancelled
```

### 3. Performance Tests
```elixir
defmodule StreamingBenchmark do
  use Benchfella
  
  @items Enum.to_list(1..10_000)
  
  bench "streaming processing" do
    {:ok, _} = StreamingTools.process_batch_stream(
      %{"items" => @items},
      &StreamingBenchmark.NullStream.handle/2
    )
  end
  
  bench "non-streaming processing" do
    {:ok, _} = Tools.process_batch(%{"items" => @items})
  end
end
```

## Monitoring and Observability

### 1. Telemetry Events
```elixir
# Emit telemetry for monitoring
:telemetry.execute(
  [:snakepit, :streaming, :chunk],
  %{size: byte_size(chunk), duration: duration},
  %{session_id: session_id, tool_name: tool_name, sequence: seq}
)

:telemetry.execute(
  [:snakepit, :streaming, :complete],
  %{total_chunks: total, total_bytes: bytes, duration: duration},
  %{session_id: session_id, tool_name: tool_name, status: status}
)
```

### 2. Metrics Collection
```python
class StreamingMetrics:
    def __init__(self):
        self.chunks_sent = Counter('streaming_chunks_sent_total')
        self.bytes_sent = Counter('streaming_bytes_sent_total')
        self.stream_duration = Histogram('streaming_duration_seconds')
        self.active_streams = Gauge('streaming_active_streams')
        
    @contextmanager
    def track_stream(self, tool_name):
        start_time = time.time()
        self.active_streams.inc()
        
        try:
            yield self
        finally:
            self.active_streams.dec()
            duration = time.time() - start_time
            self.stream_duration.labels(tool=tool_name).observe(duration)
```

## Migration Guide

### For Tool Developers

#### Converting Non-Streaming to Streaming Tool

**Before (Non-streaming):**
```python
@tool(description="Process all data at once")
def process_data(self, data: list) -> dict:
    results = []
    for item in data:
        results.append(process_item(item))
    return {"results": results}
```

**After (Streaming):**
```python
@streaming_tool(description="Process data in chunks with progress")
async def process_data_stream(self, ctx: StreamContext, data: list):
    total = len(data)
    
    for i, item in enumerate(data):
        # Process individual item
        result = process_item(item)
        
        # Emit progress
        await ctx.emit_progress(
            percent=(i + 1) / total * 100,
            message=f"Processing item {i + 1}/{total}"
        )
        
        # Yield result
        yield result
    
    # Optional: return summary
    return {"total_processed": total}
```

### For Tool Consumers

**Before (Blocking):**
```python
result = ctx.call_elixir_tool("process_data", data=large_dataset)
print(f"Processed {len(result['results'])} items")
```

**After (Streaming):**
```python
results = []
async for chunk in ctx.stream_elixir_tool("process_data_stream", data=large_dataset):
    if chunk.HasField("progress"):
        print(f"Progress: {chunk.progress.percent}% - {chunk.progress.message}")
    elif chunk.HasField("chunk"):
        results.append(chunk.chunk.data)

print(f"Processed {len(results)} items")
```

## Security Considerations

### 1. Stream Authentication
```elixir
defmodule Snakepit.Bridge.StreamAuth do
  def verify_stream_token(token, session_id) do
    # Verify token is valid for session
    # Check permissions for streaming operations
    # Validate rate limits
  end
end
```

### 2. Resource Limits
```yaml
# Configuration for stream limits
streaming:
  max_concurrent_streams_per_session: 10
  max_chunk_size_kb: 1024
  max_stream_duration_seconds: 3600
  max_buffer_size_per_stream: 100
```

### 3. Input Validation
```python
class StreamValidator:
    @staticmethod
    def validate_chunk(chunk, expected_type):
        # Validate chunk size
        if len(chunk) > MAX_CHUNK_SIZE:
            raise ValueError("Chunk exceeds maximum size")
        
        # Validate data type
        if not isinstance(chunk, expected_type):
            raise TypeError(f"Expected {expected_type}, got {type(chunk)}")
        
        # Sanitize data
        return sanitize_for_streaming(chunk)
```

## Timeline and Milestones

### Week 1: Foundation
- [ ] Extend protocol buffers with streaming messages
- [ ] Implement StreamingToolRegistry in Elixir
- [ ] Create StreamProcess GenServer
- [ ] Basic unit tests

### Week 2: Python Support
- [ ] Implement @streaming_tool decorator
- [ ] Create StreamContext class
- [ ] Client-side streaming support
- [ ] Python unit tests

### Week 3: Elixir Implementation
- [ ] BridgeServer streaming handlers
- [ ] Example Elixir streaming tools
- [ ] Integration tests
- [ ] Performance benchmarks

### Week 4: Advanced Features
- [ ] Bidirectional streaming
- [ ] Stream composition
- [ ] Error recovery
- [ ] Documentation and examples

### Week 5: Production Readiness
- [ ] Monitoring and telemetry
- [ ] Security review
- [ ] Performance optimization
- [ ] Migration guide

## Conclusion

The streaming implementation for the bidirectional tool bridge will enable:
1. Real-time progress updates for long-running operations
2. Memory-efficient processing of large datasets
3. Interactive tool execution with bidirectional communication
4. Graceful cancellation and error recovery
5. Enhanced user experience with live feedback

The implementation maintains backward compatibility while providing powerful new capabilities for both Elixir and Python developers.