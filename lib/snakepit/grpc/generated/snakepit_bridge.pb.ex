defmodule Snakepit.Bridge.PingRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:message, 1, type: :string)
end

defmodule Snakepit.Bridge.PingResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:message, 1, type: :string)
  field(:server_time, 2, type: Google.Protobuf.Timestamp, json_name: "serverTime")
end

defmodule Snakepit.Bridge.InitializeSessionRequest.MetadataEntry do
  @moduledoc false

  use Protobuf, map: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

defmodule Snakepit.Bridge.InitializeSessionRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:session_id, 1, type: :string, json_name: "sessionId")

  field(:metadata, 2,
    repeated: true,
    type: Snakepit.Bridge.InitializeSessionRequest.MetadataEntry,
    map: true
  )

  field(:config, 3, type: Snakepit.Bridge.SessionConfig)
end

defmodule Snakepit.Bridge.SessionConfig do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:enable_caching, 1, type: :bool, json_name: "enableCaching")
  field(:cache_ttl_seconds, 2, type: :int32, json_name: "cacheTtlSeconds")
  field(:enable_telemetry, 3, type: :bool, json_name: "enableTelemetry")
end

defmodule Snakepit.Bridge.InitializeSessionResponse.AvailableToolsEntry do
  @moduledoc false

  use Protobuf, map: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: Snakepit.Bridge.ToolSpec)
end

defmodule Snakepit.Bridge.InitializeSessionResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:success, 1, type: :bool)
  field(:error_message, 2, type: :string, json_name: "errorMessage")

  field(:available_tools, 3,
    repeated: true,
    type: Snakepit.Bridge.InitializeSessionResponse.AvailableToolsEntry,
    json_name: "availableTools",
    map: true
  )
end

defmodule Snakepit.Bridge.CleanupSessionRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:session_id, 1, type: :string, json_name: "sessionId")
  field(:force, 2, type: :bool)
end

defmodule Snakepit.Bridge.CleanupSessionResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:success, 1, type: :bool)
  field(:resources_cleaned, 2, type: :int32, json_name: "resourcesCleaned")
end

defmodule Snakepit.Bridge.ToolSpec.MetadataEntry do
  @moduledoc false

  use Protobuf, map: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

defmodule Snakepit.Bridge.ToolSpec do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:name, 1, type: :string)
  field(:description, 2, type: :string)
  field(:parameters, 3, repeated: true, type: Snakepit.Bridge.ParameterSpec)
  field(:metadata, 4, repeated: true, type: Snakepit.Bridge.ToolSpec.MetadataEntry, map: true)
  field(:supports_streaming, 5, type: :bool, json_name: "supportsStreaming")
end

defmodule Snakepit.Bridge.ParameterSpec do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:name, 1, type: :string)
  field(:type, 2, type: :string)
  field(:description, 3, type: :string)
  field(:required, 4, type: :bool)
  field(:default_value, 5, type: Google.Protobuf.Any, json_name: "defaultValue")
  field(:validation_json, 6, type: :string, json_name: "validationJson")
end

defmodule Snakepit.Bridge.ExecuteToolRequest.ParametersEntry do
  @moduledoc false

  use Protobuf, map: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: Google.Protobuf.Any)
end

defmodule Snakepit.Bridge.ExecuteToolRequest.MetadataEntry do
  @moduledoc false

  use Protobuf, map: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

defmodule Snakepit.Bridge.ExecuteToolRequest.BinaryParametersEntry do
  @moduledoc false

  use Protobuf, map: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :bytes)
end

defmodule Snakepit.Bridge.ExecuteToolRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:session_id, 1, type: :string, json_name: "sessionId")
  field(:tool_name, 2, type: :string, json_name: "toolName")

  field(:parameters, 3,
    repeated: true,
    type: Snakepit.Bridge.ExecuteToolRequest.ParametersEntry,
    map: true
  )

  field(:metadata, 4,
    repeated: true,
    type: Snakepit.Bridge.ExecuteToolRequest.MetadataEntry,
    map: true
  )

  field(:stream, 5, type: :bool)

  field(:binary_parameters, 6,
    repeated: true,
    type: Snakepit.Bridge.ExecuteToolRequest.BinaryParametersEntry,
    json_name: "binaryParameters",
    map: true
  )
end

defmodule Snakepit.Bridge.ExecuteToolResponse.MetadataEntry do
  @moduledoc false

  use Protobuf, map: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

defmodule Snakepit.Bridge.ExecuteToolResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:success, 1, type: :bool)
  field(:result, 2, type: Google.Protobuf.Any)
  field(:error_message, 3, type: :string, json_name: "errorMessage")

  field(:metadata, 4,
    repeated: true,
    type: Snakepit.Bridge.ExecuteToolResponse.MetadataEntry,
    map: true
  )

  field(:execution_time_ms, 5, type: :int64, json_name: "executionTimeMs")
  field(:binary_result, 6, type: :bytes, json_name: "binaryResult")
end

defmodule Snakepit.Bridge.ToolChunk.MetadataEntry do
  @moduledoc false

  use Protobuf, map: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

defmodule Snakepit.Bridge.ToolChunk do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:chunk_id, 1, type: :string, json_name: "chunkId")
  field(:data, 2, type: :bytes)
  field(:is_final, 3, type: :bool, json_name: "isFinal")
  field(:metadata, 4, repeated: true, type: Snakepit.Bridge.ToolChunk.MetadataEntry, map: true)
end

defmodule Snakepit.Bridge.GetSessionRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:session_id, 1, type: :string, json_name: "sessionId")
end

defmodule Snakepit.Bridge.GetSessionResponse.MetadataEntry do
  @moduledoc false

  use Protobuf, map: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

defmodule Snakepit.Bridge.GetSessionResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:session_id, 1, type: :string, json_name: "sessionId")

  field(:metadata, 2,
    repeated: true,
    type: Snakepit.Bridge.GetSessionResponse.MetadataEntry,
    map: true
  )

  field(:created_at, 3, type: Google.Protobuf.Timestamp, json_name: "createdAt")
  field(:tool_count, 4, type: :int32, json_name: "toolCount")
end

defmodule Snakepit.Bridge.HeartbeatRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:session_id, 1, type: :string, json_name: "sessionId")
  field(:client_time, 2, type: Google.Protobuf.Timestamp, json_name: "clientTime")
end

defmodule Snakepit.Bridge.HeartbeatResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:server_time, 1, type: Google.Protobuf.Timestamp, json_name: "serverTime")
  field(:session_valid, 2, type: :bool, json_name: "sessionValid")
end

defmodule Snakepit.Bridge.RegisterToolsRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:session_id, 1, type: :string, json_name: "sessionId")
  field(:tools, 2, repeated: true, type: Snakepit.Bridge.ToolRegistration)
  field(:worker_id, 3, type: :string, json_name: "workerId")
end

defmodule Snakepit.Bridge.ToolRegistration.MetadataEntry do
  @moduledoc false

  use Protobuf, map: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

defmodule Snakepit.Bridge.ToolRegistration do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:name, 1, type: :string)
  field(:description, 2, type: :string)
  field(:parameters, 3, repeated: true, type: Snakepit.Bridge.ParameterSpec)

  field(:metadata, 4,
    repeated: true,
    type: Snakepit.Bridge.ToolRegistration.MetadataEntry,
    map: true
  )

  field(:supports_streaming, 5, type: :bool, json_name: "supportsStreaming")
end

defmodule Snakepit.Bridge.RegisterToolsResponse.ToolIdsEntry do
  @moduledoc false

  use Protobuf, map: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

defmodule Snakepit.Bridge.RegisterToolsResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:success, 1, type: :bool)

  field(:tool_ids, 2,
    repeated: true,
    type: Snakepit.Bridge.RegisterToolsResponse.ToolIdsEntry,
    json_name: "toolIds",
    map: true
  )

  field(:error_message, 3, type: :string, json_name: "errorMessage")
end

defmodule Snakepit.Bridge.GetExposedElixirToolsRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:session_id, 1, type: :string, json_name: "sessionId")
end

defmodule Snakepit.Bridge.GetExposedElixirToolsResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:tools, 1, repeated: true, type: Snakepit.Bridge.ToolSpec)
end

defmodule Snakepit.Bridge.ExecuteElixirToolRequest.ParametersEntry do
  @moduledoc false

  use Protobuf, map: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: Google.Protobuf.Any)
end

defmodule Snakepit.Bridge.ExecuteElixirToolRequest.MetadataEntry do
  @moduledoc false

  use Protobuf, map: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

defmodule Snakepit.Bridge.ExecuteElixirToolRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:session_id, 1, type: :string, json_name: "sessionId")
  field(:tool_name, 2, type: :string, json_name: "toolName")

  field(:parameters, 3,
    repeated: true,
    type: Snakepit.Bridge.ExecuteElixirToolRequest.ParametersEntry,
    map: true
  )

  field(:metadata, 4,
    repeated: true,
    type: Snakepit.Bridge.ExecuteElixirToolRequest.MetadataEntry,
    map: true
  )
end

defmodule Snakepit.Bridge.ExecuteElixirToolResponse.MetadataEntry do
  @moduledoc false

  use Protobuf, map: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

defmodule Snakepit.Bridge.ExecuteElixirToolResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:success, 1, type: :bool)
  field(:result, 2, type: Google.Protobuf.Any)
  field(:error_message, 3, type: :string, json_name: "errorMessage")

  field(:metadata, 4,
    repeated: true,
    type: Snakepit.Bridge.ExecuteElixirToolResponse.MetadataEntry,
    map: true
  )

  field(:execution_time_ms, 5, type: :int64, json_name: "executionTimeMs")
  field(:binary_result, 6, type: :bytes, json_name: "binaryResult")
end

defmodule Snakepit.Bridge.TelemetryEvent.MeasurementsEntry do
  @moduledoc false

  use Protobuf, map: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: Snakepit.Bridge.TelemetryValue)
end

defmodule Snakepit.Bridge.TelemetryEvent.MetadataEntry do
  @moduledoc false

  use Protobuf, map: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

defmodule Snakepit.Bridge.TelemetryEvent do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:event_parts, 1, repeated: true, type: :string, json_name: "eventParts")

  field(:measurements, 2,
    repeated: true,
    type: Snakepit.Bridge.TelemetryEvent.MeasurementsEntry,
    map: true
  )

  field(:metadata, 3,
    repeated: true,
    type: Snakepit.Bridge.TelemetryEvent.MetadataEntry,
    map: true
  )

  field(:timestamp_ns, 4, type: :int64, json_name: "timestampNs")
  field(:correlation_id, 5, type: :string, json_name: "correlationId")
end

defmodule Snakepit.Bridge.TelemetryValue do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  oneof(:value, 0)

  field(:int_value, 1, type: :int64, json_name: "intValue", oneof: 0)
  field(:float_value, 2, type: :double, json_name: "floatValue", oneof: 0)
  field(:string_value, 3, type: :string, json_name: "stringValue", oneof: 0)
end

defmodule Snakepit.Bridge.TelemetryControl do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  oneof(:control, 0)

  field(:toggle, 1, type: Snakepit.Bridge.TelemetryToggle, oneof: 0)
  field(:sampling, 2, type: Snakepit.Bridge.TelemetrySamplingUpdate, oneof: 0)
  field(:filter, 3, type: Snakepit.Bridge.TelemetryEventFilter, oneof: 0)
end

defmodule Snakepit.Bridge.TelemetryToggle do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:enabled, 1, type: :bool)
end

defmodule Snakepit.Bridge.TelemetrySamplingUpdate do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:sampling_rate, 1, type: :double, json_name: "samplingRate")
  field(:event_patterns, 2, repeated: true, type: :string, json_name: "eventPatterns")
end

defmodule Snakepit.Bridge.TelemetryEventFilter do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:allow, 1, repeated: true, type: :string)
  field(:deny, 2, repeated: true, type: :string)
end

defmodule Snakepit.Bridge.BridgeService.Service do
  @moduledoc false

  use GRPC.Service, name: "snakepit.bridge.BridgeService", protoc_gen_elixir_version: "0.15.0"

  rpc(:Ping, Snakepit.Bridge.PingRequest, Snakepit.Bridge.PingResponse)

  rpc(
    :InitializeSession,
    Snakepit.Bridge.InitializeSessionRequest,
    Snakepit.Bridge.InitializeSessionResponse
  )

  rpc(
    :CleanupSession,
    Snakepit.Bridge.CleanupSessionRequest,
    Snakepit.Bridge.CleanupSessionResponse
  )

  rpc(:GetSession, Snakepit.Bridge.GetSessionRequest, Snakepit.Bridge.GetSessionResponse)

  rpc(:Heartbeat, Snakepit.Bridge.HeartbeatRequest, Snakepit.Bridge.HeartbeatResponse)

  rpc(:ExecuteTool, Snakepit.Bridge.ExecuteToolRequest, Snakepit.Bridge.ExecuteToolResponse)

  rpc(
    :ExecuteStreamingTool,
    Snakepit.Bridge.ExecuteToolRequest,
    stream(Snakepit.Bridge.ToolChunk)
  )

  rpc(:RegisterTools, Snakepit.Bridge.RegisterToolsRequest, Snakepit.Bridge.RegisterToolsResponse)

  rpc(
    :GetExposedElixirTools,
    Snakepit.Bridge.GetExposedElixirToolsRequest,
    Snakepit.Bridge.GetExposedElixirToolsResponse
  )

  rpc(
    :ExecuteElixirTool,
    Snakepit.Bridge.ExecuteElixirToolRequest,
    Snakepit.Bridge.ExecuteElixirToolResponse
  )

  rpc(
    :StreamTelemetry,
    stream(Snakepit.Bridge.TelemetryControl),
    stream(Snakepit.Bridge.TelemetryEvent)
  )
end

defmodule Snakepit.Bridge.BridgeService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Snakepit.Bridge.BridgeService.Service
end
