# Design Document

## Overview

The gRPC Protocol Extension provides the integration layer that connects Snakepit's zero-copy capabilities with the existing gRPC communication infrastructure. This design ensures seamless, transparent operation where users benefit from zero-copy performance without changing their application code, while maintaining 100% backward compatibility with existing deployments.

The architecture emphasizes:
- **Transparency**: Zero-copy works through existing APIs without code changes
- **Compatibility**: Full backward compatibility with v0.6.0 and v0.7.0
- **Safety**: Robust error handling with automatic fallback to traditional serialization
- **Performance**: Minimal protocol overhead for zero-copy operations
- **Security**: Comprehensive access control and validation for shared memory references

## Architecture

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Application Layer                            │
│                                                                 │
│  Snakepit.execute(command, args) ──────────────────────────┐   │
└────────────────────────────────────────────────────────────┼───┘
                                                             │
┌────────────────────────────────────────────────────────────▼───┐
│              gRPC Protocol Extension Layer                     │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │  Protocol Coordinator                                    │ │
│  │  - Capability negotiation                                │ │
│  │  - Transfer method selection                             │ │
│  │  - Request/response routing                              │ │
│  └──────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
         │                    │                    │
         ▼                    ▼                    ▼
┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
│ Message          │ │ Reference        │ │ Fallback         │
│ Transformer      │ │ Manager          │ │ Handler          │
│                  │ │                  │ │                  │
│ - Detect large   │ │ - Create refs    │ │ - Detect         │
│   data           │ │ - Validate refs  │ │   failures       │
│ - Create refs    │ │ - Security       │ │ - Switch to      │
│ - Serialize      │ │   tokens         │ │   traditional    │
│   metadata       │ │ - Lifecycle      │ │ - Track          │
└──────────────────┘ └──────────────────┘ └──────────────────┘
         │                    │                    │
         └────────────────────┼────────────────────┘
                              ▼
                   ┌──────────────────────┐
                   │ Integration Layer    │
                   │                      │
                   │ - Shared Memory Mgmt │
                   │ - Serialization      │
                   │ - Memory Safety      │
                   │ - Performance Opt    │
                   └──────────────────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │ gRPC Transport       │
                   │                      │
                   │ - Traditional path   │
                   │ - Zero-copy path     │
                   │ - Streaming          │
                   └──────────────────────┘
```

### Protocol Flow

#### Traditional Serialization Flow (v0.7.0 and earlier)

```
1. Application calls Snakepit.execute(command, args)
   ↓
2. Serialize args to Protobuf
   ↓
3. Send ExecuteToolRequest via gRPC
   ↓
4. Python worker receives and deserializes
   ↓
5. Execute command
   ↓
6. Serialize result to Protobuf
   ↓
7. Send ToolResponse via gRPC
   ↓
8. Elixir deserializes and returns to application
```

#### Zero-Copy Flow (v0.8.0)

```
1. Application calls Snakepit.execute(command, args)
   ↓
2. Protocol Coordinator checks data size and performance optimization
   ↓
3. IF data > threshold:
   a. Allocate shared memory region
   b. Write data to shared memory
   c. Create SharedMemoryRef with security token
   d. Send ExecuteToolRequest with ref (not data)
   ↓
4. Python worker receives request
   ↓
5. Validate SharedMemoryRef and security token
   ↓
6. Map shared memory region (zero-copy)
   ↓
7. Execute command with memory-mapped data
   ↓
8. IF result > threshold:
   a. Write result to shared memory
   b. Create SharedMemoryRef for result
   c. Send ToolResponse with ref (not data)
   ELSE:
   a. Send ToolResponse with traditional serialization
   ↓
9. Elixir receives response
   ↓
10. IF response has SharedMemoryRef:
    a. Validate ref and security token
    b. Map shared memory region
    c. Read result (zero-copy)
    d. Cleanup shared memory
    ↓
11. Return result to application
```

## Components and Interfaces

### 1. Protocol Coordinator

**Responsibility**: Orchestrate protocol operations and coordinate subsystems.

**Interface**:
```elixir
defmodule Snakepit.Protocol.Coordinator do
  @doc """
  Execute a command with automatic transfer method selection.
  """
  @spec execute(command :: String.t(), args :: map(), opts :: keyword()) ::
    {:ok, result :: term()} | {:error, reason :: term()}
  
  @doc """
  Negotiate protocol capabilities with remote endpoint.
  """
  @spec negotiate_capabilities(connection :: pid()) ::
    {:ok, capabilities :: map()} | {:error, reason :: term()}
  
  @doc """
  Get protocol statistics for monitoring.
  """
  @spec get_statistics() :: {:ok, stats :: map()}
end
```

**Implementation**:
```elixir
defmodule Snakepit.Protocol.Coordinator do
  use GenServer
  
  def execute(command, args, opts) do
    GenServer.call(__MODULE__, {:execute, command, args, opts})
  end
  
  def init(opts) do
    state = %{
      capabilities: %{
        zero_copy_supported: true,
        max_shared_memory_size: 1_073_741_824,  # 1GB
        supported_formats: [:arrow, :numpy, :raw]
      },
      connections: %{},  # connection_id => capabilities
      statistics: init_statistics(),
      config: opts
    }
    
    {:ok, state}
  end
  
  def handle_call({:execute, command, args, opts}, _from, state) do
    start_time = System.monotonic_time(:microsecond)
    
    # Check if zero-copy should be used
    case should_use_zero_copy?(args, opts, state) do
      true ->
        case execute_with_zero_copy(command, args, opts, state) do
          {:ok, result} ->
            duration = System.monotonic_time(:microsecond) - start_time
            updated_state = update_statistics(state, :zero_copy, duration, :success)
            {:reply, {:ok, result}, updated_state}
          
          {:error, reason} ->
            # Fallback to traditional serialization
            Logger.warning("Zero-copy failed: #{inspect(reason)}, falling back to traditional")
            case execute_traditional(command, args, opts, state) do
              {:ok, result} ->
                duration = System.monotonic_time(:microsecond) - start_time
                updated_state = update_statistics(state, :fallback, duration, :success)
                {:reply, {:ok, result}, updated_state}
              
              {:error, fallback_reason} ->
                {:reply, {:error, fallback_reason}, state}
            end
        end
      
      false ->
        case execute_traditional(command, args, opts, state) do
          {:ok, result} ->
            duration = System.monotonic_time(:microsecond) - start_time
            updated_state = update_statistics(state, :traditional, duration, :success)
            {:reply, {:ok, result}, updated_state}
          
          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end
  
  defp should_use_zero_copy?(args, opts, state) do
    # Check if explicitly disabled
    if opts[:zero_copy] == false do
      false
    else
      # Check data size and performance optimization decision
      data_size = estimate_data_size(args)
      
      case Performance.Controller.decide_transfer_method(args, %{size: data_size}) do
        {:zero_copy, _metadata} -> true
        {:grpc, _metadata} -> false
      end
    end
  end
  
  defp execute_with_zero_copy(command, args, opts, state) do
    # Transform args to use shared memory references
    case MessageTransformer.transform_to_zero_copy(args) do
      {:ok, transformed_args, shared_memory_refs} ->
        # Execute via gRPC with shared memory references
        case GRPCClient.execute(command, transformed_args, opts) do
          {:ok, response} ->
            # Transform response back from shared memory references
            result = MessageTransformer.transform_from_zero_copy(response)
            
            # Cleanup shared memory
            cleanup_shared_memory(shared_memory_refs)
            
            {:ok, result}
          
          {:error, reason} ->
            cleanup_shared_memory(shared_memory_refs)
            {:error, reason}
        end
      
      {:error, reason} ->
        {:error, reason}
    end
  end
  
  defp execute_traditional(command, args, opts, _state) do
    # Traditional gRPC execution
    GRPCClient.execute(command, args, opts)
  end
end
```

### 2. Message Transformer

**Responsibility**: Transform messages between traditional and zero-copy formats.

**Interface**:
```elixir
defmodule Snakepit.Protocol.MessageTransformer do
  @doc """
  Transform arguments to use shared memory references for large data.
  """
  @spec transform_to_zero_copy(args :: map()) ::
    {:ok, transformed :: map(), refs :: [String.t()]} | {:error, reason :: term()}
  
  @doc """
  Transform response from shared memory references back to data.
  """
  @spec transform_from_zero_copy(response :: map()) ::
    term()
  
  @doc """
  Estimate serialized size of data.
  """
  @spec estimate_size(data :: term()) :: non_neg_integer()
end
```

**Implementation**:
```elixir
defmodule Snakepit.Protocol.MessageTransformer do
  @threshold 10 * 1024 * 1024  # 10MB default threshold
  
  def transform_to_zero_copy(args) do
    {transformed, refs} = 
      Enum.reduce(args, {%{}, []}, fn {key, value}, {acc_args, acc_refs} ->
        case should_use_shared_memory?(value) do
          true ->
            case create_shared_memory_ref(value) do
              {:ok, ref} ->
                {Map.put(acc_args, key, ref), [ref.region_id | acc_refs]}
              
              {:error, _reason} ->
                # Keep original value if shared memory creation fails
                {Map.put(acc_args, key, value), acc_refs}
            end
          
          false ->
            {Map.put(acc_args, key, value), acc_refs}
        end
      end)
    
    {:ok, transformed, refs}
  end
  
  def transform_from_zero_copy(response) do
    case response do
      %{shared_memory_ref: ref} ->
        # Read from shared memory
        case SharedMemory.Manager.read_region(ref.region_id) do
          {:ok, data} ->
            # Cleanup
            SharedMemory.Manager.release_region(ref.region_id)
            data
          
          {:error, reason} ->
            {:error, {:shared_memory_read_failed, reason}}
        end
      
      %{result: result} ->
        # Traditional response
        result
      
      other ->
        other
    end
  end
  
  defp should_use_shared_memory?(value) do
    size = estimate_size(value)
    size >= @threshold
  end
  
  defp create_shared_memory_ref(value) do
    size = estimate_size(value)
    
    # Allocate shared memory
    case SharedMemory.Manager.allocate_region(size) do
      {:ok, region_id} ->
        # Write data to shared memory
        case SharedMemory.Manager.write_region(region_id, value) do
          :ok ->
            # Create reference with security token
            ref = %{
              region_id: region_id,
              path: SharedMemory.Manager.get_region_path(region_id),
              size: size,
              format: determine_format(value),
              security_token: generate_security_token(region_id),
              expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
            }
            
            {:ok, ref}
          
          {:error, reason} ->
            SharedMemory.Manager.release_region(region_id)
            {:error, reason}
        end
      
      {:error, reason} ->
        {:error, reason}
    end
  end
  
  def estimate_size(value) when is_binary(value), do: byte_size(value)
  def estimate_size(value) when is_list(value), do: :erlang.external_size(value)
  def estimate_size(value) when is_map(value), do: :erlang.external_size(value)
  def estimate_size(_value), do: 0
  
  defp determine_format(value) do
    cond do
      is_binary(value) -> :raw
      is_list(value) -> :arrow
      is_map(value) -> :arrow
      true -> :raw
    end
  end
  
  defp generate_security_token(region_id) do
    # Generate HMAC-based security token
    secret = Application.get_env(:snakepit, :shared_memory_secret)
    :crypto.mac(:hmac, :sha256, secret, region_id)
    |> Base.encode64()
  end
end
```

### 3. Reference Manager

**Responsibility**: Manage shared memory reference lifecycle and security.

**Interface**:
```elixir
defmodule Snakepit.Protocol.ReferenceManager do
  @doc """
  Create a shared memory reference with security token.
  """
  @spec create_reference(region_id :: String.t(), metadata :: map()) ::
    {:ok, reference :: map()} | {:error, reason :: term()}
  
  @doc """
  Validate a shared memory reference and security token.
  """
  @spec validate_reference(reference :: map()) ::
    :ok | {:error, reason :: term()}
  
  @doc """
  Cleanup expired references.
  """
  @spec cleanup_expired_references() :: :ok
end
```

**Implementation**:
```elixir
defmodule Snakepit.Protocol.ReferenceManager do
  use GenServer
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  def create_reference(region_id, metadata) do
    GenServer.call(__MODULE__, {:create_reference, region_id, metadata})
  end
  
  def validate_reference(reference) do
    GenServer.call(__MODULE__, {:validate_reference, reference})
  end
  
  def init(opts) do
    state = %{
      active_references: %{},  # region_id => reference_info
      config: opts
    }
    
    # Schedule periodic cleanup
    schedule_cleanup()
    
    {:ok, state}
  end
  
  def handle_call({:create_reference, region_id, metadata}, _from, state) do
    reference = %{
      region_id: region_id,
      path: metadata[:path],
      size: metadata[:size],
      format: metadata[:format],
      security_token: generate_security_token(region_id),
      created_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
      metadata: metadata
    }
    
    # Store reference info
    ref_info = %{
      reference: reference,
      created_at: DateTime.utc_now(),
      access_count: 0
    }
    
    updated_state = put_in(state, [:active_references, region_id], ref_info)
    
    {:reply, {:ok, reference}, updated_state}
  end
  
  def handle_call({:validate_reference, reference}, _from, state) do
    case validate_reference_internal(reference, state) do
      :ok ->
        # Update access count
        updated_state = update_in(
          state,
          [:active_references, reference.region_id, :access_count],
          &(&1 + 1)
        )
        {:reply, :ok, updated_state}
      
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end
  
  def handle_info(:cleanup_expired, state) do
    now = DateTime.utc_now()
    
    expired = 
      Enum.filter(state.active_references, fn {_region_id, ref_info} ->
        DateTime.compare(ref_info.reference.expires_at, now) == :lt
      end)
    
    # Cleanup expired references
    Enum.each(expired, fn {region_id, _ref_info} ->
      Logger.info("Cleaning up expired reference: #{region_id}")
      SharedMemory.Manager.release_region(region_id)
    end)
    
    # Remove from state
    updated_state = 
      update_in(state, [:active_references], fn refs ->
        Map.drop(refs, Enum.map(expired, fn {region_id, _} -> region_id end))
      end)
    
    schedule_cleanup()
    {:noreply, updated_state}
  end
  
  defp validate_reference_internal(reference, state) do
    cond do
      # Check if reference exists
      not Map.has_key?(state.active_references, reference.region_id) ->
        {:error, :reference_not_found}
      
      # Check if expired
      DateTime.compare(reference.expires_at, DateTime.utc_now()) == :lt ->
        {:error, :reference_expired}
      
      # Validate security token
      not valid_security_token?(reference) ->
        {:error, :invalid_security_token}
      
      true ->
        :ok
    end
  end
  
  defp valid_security_token?(reference) do
    expected_token = generate_security_token(reference.region_id)
    reference.security_token == expected_token
  end
  
  defp generate_security_token(region_id) do
    secret = Application.get_env(:snakepit, :shared_memory_secret)
    :crypto.mac(:hmac, :sha256, secret, region_id)
    |> Base.encode64()
  end
  
  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_expired, 10_000)  # Every 10 seconds
  end
end
```

### 4. Protocol Buffer Definitions

**Extended Protocol Definitions**:

```protobuf
// snakepit_bridge_v2.proto

syntax = "proto3";

package snakepit.v2;

// Shared memory reference for zero-copy data transfer
message SharedMemoryRef {
  string region_id = 1;
  string path = 2;
  uint64 size = 3;
  string format = 4;  // "arrow", "numpy", "raw"
  string security_token = 5;
  int64 expires_at = 6;  // Unix timestamp
  map<string, string> metadata = 7;
}

// Extended execute request supporting both traditional and zero-copy
message ExecuteToolRequest {
  string session_id = 1;
  string tool_name = 2;
  
  // Protocol version for capability negotiation
  uint32 protocol_version = 3;
  
  // Parameters can be traditional or zero-copy
  oneof parameters {
    string json_parameters = 4;
    bytes binary_parameters = 5;
    SharedMemoryRef shared_memory_parameters = 6;
  }
  
  // Request metadata
  map<string, string> metadata = 7;
}

// Extended response supporting both traditional and zero-copy
message ToolResponse {
  bool success = 1;
  string error = 2;
  
  // Result can be traditional or zero-copy
  oneof result {
    string json_result = 3;
    bytes binary_result = 4;
    SharedMemoryRef shared_memory_result = 5;
  }
  
  // Response metadata
  map<string, string> metadata = 6;
}

// Capability negotiation message
message CapabilityNegotiation {
  uint32 protocol_version = 1;
  bool zero_copy_supported = 2;
  uint64 max_shared_memory_size = 3;
  repeated string supported_formats = 4;
  map<string, string> extensions = 5;
}

// Streaming support
message StreamElement {
  uint64 sequence_number = 1;
  
  oneof data {
    bytes chunk = 2;
    SharedMemoryRef shared_memory_chunk = 3;
  }
  
  bool is_last = 4;
}
```

### 5. Python Bridge Integration

**Python Side Implementation**:

```python
# snakepit_bridge/protocol_extension.py

from typing import Any, Optional, Union
import grpc
from . import snakepit_bridge_v2_pb2 as pb2
from .zero_copy import SharedMemoryView, SharedMemoryWriter

class ProtocolExtension:
    """
    Python-side protocol extension for zero-copy support.
    """
    
    def __init__(self, config: dict):
        self.config = config
        self.zero_copy_enabled = config.get('zero_copy_enabled', True)
        self.threshold = config.get('zero_copy_threshold', 10 * 1024 * 1024)
    
    def handle_request(self, request: pb2.ExecuteToolRequest) -> Any:
        """
        Handle incoming request, automatically handling zero-copy references.
        """
        # Check if request uses shared memory
        if request.HasField('shared_memory_parameters'):
            return self._handle_zero_copy_request(request)
        else:
            return self._handle_traditional_request(request)
    
    def _handle_zero_copy_request(self, request: pb2.ExecuteToolRequest) -> Any:
        """
        Handle request with shared memory parameters.
        """
        ref = request.shared_memory_parameters
        
        # Validate reference
        if not self._validate_reference(ref):
            raise ValueError(f"Invalid shared memory reference: {ref.region_id}")
        
        # Map shared memory (zero-copy)
        with SharedMemoryView(
            region_id=ref.region_id,
            path=ref.path,
            size=ref.size,
            format=ref.format
        ) as data:
            # Data is now available as NumPy array or similar
            return data
    
    def _handle_traditional_request(self, request: pb2.ExecuteToolRequest) -> Any:
        """
        Handle traditional request with serialized parameters.
        """
        if request.HasField('json_parameters'):
            import json
            return json.loads(request.json_parameters)
        elif request.HasField('binary_parameters'):
            import pickle
            return pickle.loads(request.binary_parameters)
        else:
            return None
    
    def create_response(self, result: Any) -> pb2.ToolResponse:
        """
        Create response, automatically using zero-copy for large results.
        """
        if self._should_use_zero_copy(result):
            return self._create_zero_copy_response(result)
        else:
            return self._create_traditional_response(result)
    
    def _should_use_zero_copy(self, result: Any) -> bool:
        """
        Determine if result should use zero-copy.
        """
        if not self.zero_copy_enabled:
            return False
        
        size = self._estimate_size(result)
        return size >= self.threshold
    
    def _create_zero_copy_response(self, result: Any) -> pb2.ToolResponse:
        """
        Create response with shared memory reference.
        """
        size = self._estimate_size(result)
        
        # Write to shared memory
        with SharedMemoryWriter(size, format="arrow") as writer:
            metadata = writer.write(result)
            ref = writer.get_reference()
            
            # Create protobuf response
            response = pb2.ToolResponse(
                success=True,
                shared_memory_result=pb2.SharedMemoryRef(
                    region_id=ref['region_id'],
                    path=ref['path'],
                    size=ref['size'],
                    format=ref['format'],
                    security_token=self._generate_security_token(ref['region_id']),
                    expires_at=int(time.time()) + 60
                )
            )
            
            return response
    
    def _create_traditional_response(self, result: Any) -> pb2.ToolResponse:
        """
        Create traditional response with serialized result.
        """
        import json
        
        response = pb2.ToolResponse(
            success=True,
            json_result=json.dumps(result)
        )
        
        return response
    
    def _validate_reference(self, ref: pb2.SharedMemoryRef) -> bool:
        """
        Validate shared memory reference and security token.
        """
        # Check expiration
        if ref.expires_at < int(time.time()):
            return False
        
        # Validate security token
        expected_token = self._generate_security_token(ref.region_id)
        return ref.security_token == expected_token
    
    def _generate_security_token(self, region_id: str) -> str:
        """
        Generate security token for shared memory reference.
        """
        import hmac
        import hashlib
        import base64
        
        secret = self.config.get('shared_memory_secret', b'default_secret')
        token = hmac.new(secret, region_id.encode(), hashlib.sha256).digest()
        return base64.b64encode(token).decode()
    
    def _estimate_size(self, data: Any) -> int:
        """
        Estimate size of data in bytes.
        """
        import sys
        import numpy as np
        
        if isinstance(data, np.ndarray):
            return data.nbytes
        elif isinstance(data, (bytes, bytearray)):
            return len(data)
        else:
            return sys.getsizeof(data)
```

## Error Handling

### Fallback Strategy

```elixir
defmodule Snakepit.Protocol.FallbackHandler do
  @doc """
  Handle zero-copy failure with automatic fallback.
  """
  def handle_zero_copy_failure(command, args, error, opts) do
    Logger.warning("""
    Zero-copy execution failed: #{inspect(error)}
    Falling back to traditional serialization
    Command: #{command}
    """)
    
    # Emit telemetry
    :telemetry.execute(
      [:snakepit, :protocol, :fallback],
      %{count: 1},
      %{command: command, reason: error}
    )
    
    # Execute with traditional serialization
    case GRPCClient.execute_traditional(command, args, opts) do
      {:ok, result} ->
        {:ok, result}
      
      {:error, fallback_error} ->
        Logger.error("Fallback also failed: #{inspect(fallback_error)}")
        {:error, {:fallback_failed, fallback_error}}
    end
  end
end
```

## Configuration

### Default Configuration

```elixir
config :snakepit, :protocol_extension,
  # Enable zero-copy protocol extension
  enabled: true,
  
  # Protocol version
  protocol_version: 2,
  
  # Backward compatibility
  support_v1_protocol: true,
  auto_negotiate: true,
  
  # Security
  shared_memory_secret: System.get_env("SNAKEPIT_SHARED_MEMORY_SECRET"),
  reference_ttl_seconds: 60,
  validate_security_tokens: true,
  
  # Performance
  zero_copy_threshold_bytes: 10_485_760,  # 10MB
  max_shared_memory_size: 1_073_741_824,  # 1GB
  
  # Fallback behavior
  auto_fallback_on_error: true,
  fallback_retry_count: 3,
  disable_zero_copy_on_repeated_failures: true,
  failure_threshold: 10,
  
  # Monitoring
  emit_telemetry: true,
  log_transfer_method: true,
  track_fallback_rate: true
```

## Testing Strategy

### Unit Tests
- Protocol message transformation
- Reference creation and validation
- Security token generation and verification
- Fallback logic

### Integration Tests
- End-to-end zero-copy flow
- Backward compatibility with v0.7.0
- Fallback scenarios
- Streaming with shared memory

### Performance Tests
- Protocol overhead measurement
- Zero-copy vs traditional comparison
- Fallback performance impact
- Concurrent request handling

### Compatibility Tests
- Cross-version communication
- Protocol negotiation
- Graceful degradation
- Version mismatch handling

This design provides a robust, transparent, and backward-compatible protocol extension that seamlessly integrates zero-copy capabilities into Snakepit's existing gRPC infrastructure.
