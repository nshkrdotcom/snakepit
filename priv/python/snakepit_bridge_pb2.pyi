import datetime

from google.protobuf import any_pb2 as _any_pb2
from google.protobuf import timestamp_pb2 as _timestamp_pb2
from google.protobuf.internal import containers as _containers
from google.protobuf import descriptor as _descriptor
from google.protobuf import message as _message
from collections.abc import Iterable as _Iterable, Mapping as _Mapping
from typing import ClassVar as _ClassVar, Optional as _Optional, Union as _Union

DESCRIPTOR: _descriptor.FileDescriptor

class PingRequest(_message.Message):
    __slots__ = ("message",)
    MESSAGE_FIELD_NUMBER: _ClassVar[int]
    message: str
    def __init__(self, message: _Optional[str] = ...) -> None: ...

class PingResponse(_message.Message):
    __slots__ = ("message", "server_time")
    MESSAGE_FIELD_NUMBER: _ClassVar[int]
    SERVER_TIME_FIELD_NUMBER: _ClassVar[int]
    message: str
    server_time: _timestamp_pb2.Timestamp
    def __init__(self, message: _Optional[str] = ..., server_time: _Optional[_Union[datetime.datetime, _timestamp_pb2.Timestamp, _Mapping]] = ...) -> None: ...

class InitializeSessionRequest(_message.Message):
    __slots__ = ("session_id", "metadata", "config")
    class MetadataEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: str
        def __init__(self, key: _Optional[str] = ..., value: _Optional[str] = ...) -> None: ...
    SESSION_ID_FIELD_NUMBER: _ClassVar[int]
    METADATA_FIELD_NUMBER: _ClassVar[int]
    CONFIG_FIELD_NUMBER: _ClassVar[int]
    session_id: str
    metadata: _containers.ScalarMap[str, str]
    config: SessionConfig
    def __init__(self, session_id: _Optional[str] = ..., metadata: _Optional[_Mapping[str, str]] = ..., config: _Optional[_Union[SessionConfig, _Mapping]] = ...) -> None: ...

class SessionConfig(_message.Message):
    __slots__ = ("enable_caching", "cache_ttl_seconds", "enable_telemetry")
    ENABLE_CACHING_FIELD_NUMBER: _ClassVar[int]
    CACHE_TTL_SECONDS_FIELD_NUMBER: _ClassVar[int]
    ENABLE_TELEMETRY_FIELD_NUMBER: _ClassVar[int]
    enable_caching: bool
    cache_ttl_seconds: int
    enable_telemetry: bool
    def __init__(self, enable_caching: bool = ..., cache_ttl_seconds: _Optional[int] = ..., enable_telemetry: bool = ...) -> None: ...

class InitializeSessionResponse(_message.Message):
    __slots__ = ("success", "error_message", "available_tools")
    class AvailableToolsEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: ToolSpec
        def __init__(self, key: _Optional[str] = ..., value: _Optional[_Union[ToolSpec, _Mapping]] = ...) -> None: ...
    SUCCESS_FIELD_NUMBER: _ClassVar[int]
    ERROR_MESSAGE_FIELD_NUMBER: _ClassVar[int]
    AVAILABLE_TOOLS_FIELD_NUMBER: _ClassVar[int]
    success: bool
    error_message: str
    available_tools: _containers.MessageMap[str, ToolSpec]
    def __init__(self, success: bool = ..., error_message: _Optional[str] = ..., available_tools: _Optional[_Mapping[str, ToolSpec]] = ...) -> None: ...

class CleanupSessionRequest(_message.Message):
    __slots__ = ("session_id", "force")
    SESSION_ID_FIELD_NUMBER: _ClassVar[int]
    FORCE_FIELD_NUMBER: _ClassVar[int]
    session_id: str
    force: bool
    def __init__(self, session_id: _Optional[str] = ..., force: bool = ...) -> None: ...

class CleanupSessionResponse(_message.Message):
    __slots__ = ("success", "resources_cleaned")
    SUCCESS_FIELD_NUMBER: _ClassVar[int]
    RESOURCES_CLEANED_FIELD_NUMBER: _ClassVar[int]
    success: bool
    resources_cleaned: int
    def __init__(self, success: bool = ..., resources_cleaned: _Optional[int] = ...) -> None: ...

class ToolSpec(_message.Message):
    __slots__ = ("name", "description", "parameters", "metadata", "supports_streaming")
    class MetadataEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: str
        def __init__(self, key: _Optional[str] = ..., value: _Optional[str] = ...) -> None: ...
    NAME_FIELD_NUMBER: _ClassVar[int]
    DESCRIPTION_FIELD_NUMBER: _ClassVar[int]
    PARAMETERS_FIELD_NUMBER: _ClassVar[int]
    METADATA_FIELD_NUMBER: _ClassVar[int]
    SUPPORTS_STREAMING_FIELD_NUMBER: _ClassVar[int]
    name: str
    description: str
    parameters: _containers.RepeatedCompositeFieldContainer[ParameterSpec]
    metadata: _containers.ScalarMap[str, str]
    supports_streaming: bool
    def __init__(self, name: _Optional[str] = ..., description: _Optional[str] = ..., parameters: _Optional[_Iterable[_Union[ParameterSpec, _Mapping]]] = ..., metadata: _Optional[_Mapping[str, str]] = ..., supports_streaming: bool = ...) -> None: ...

class ParameterSpec(_message.Message):
    __slots__ = ("name", "type", "description", "required", "default_value", "validation_json")
    NAME_FIELD_NUMBER: _ClassVar[int]
    TYPE_FIELD_NUMBER: _ClassVar[int]
    DESCRIPTION_FIELD_NUMBER: _ClassVar[int]
    REQUIRED_FIELD_NUMBER: _ClassVar[int]
    DEFAULT_VALUE_FIELD_NUMBER: _ClassVar[int]
    VALIDATION_JSON_FIELD_NUMBER: _ClassVar[int]
    name: str
    type: str
    description: str
    required: bool
    default_value: _any_pb2.Any
    validation_json: str
    def __init__(self, name: _Optional[str] = ..., type: _Optional[str] = ..., description: _Optional[str] = ..., required: bool = ..., default_value: _Optional[_Union[_any_pb2.Any, _Mapping]] = ..., validation_json: _Optional[str] = ...) -> None: ...

class ExecuteToolRequest(_message.Message):
    __slots__ = ("session_id", "tool_name", "parameters", "metadata", "stream", "binary_parameters")
    class ParametersEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: _any_pb2.Any
        def __init__(self, key: _Optional[str] = ..., value: _Optional[_Union[_any_pb2.Any, _Mapping]] = ...) -> None: ...
    class MetadataEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: str
        def __init__(self, key: _Optional[str] = ..., value: _Optional[str] = ...) -> None: ...
    class BinaryParametersEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: bytes
        def __init__(self, key: _Optional[str] = ..., value: _Optional[bytes] = ...) -> None: ...
    SESSION_ID_FIELD_NUMBER: _ClassVar[int]
    TOOL_NAME_FIELD_NUMBER: _ClassVar[int]
    PARAMETERS_FIELD_NUMBER: _ClassVar[int]
    METADATA_FIELD_NUMBER: _ClassVar[int]
    STREAM_FIELD_NUMBER: _ClassVar[int]
    BINARY_PARAMETERS_FIELD_NUMBER: _ClassVar[int]
    session_id: str
    tool_name: str
    parameters: _containers.MessageMap[str, _any_pb2.Any]
    metadata: _containers.ScalarMap[str, str]
    stream: bool
    binary_parameters: _containers.ScalarMap[str, bytes]
    def __init__(self, session_id: _Optional[str] = ..., tool_name: _Optional[str] = ..., parameters: _Optional[_Mapping[str, _any_pb2.Any]] = ..., metadata: _Optional[_Mapping[str, str]] = ..., stream: bool = ..., binary_parameters: _Optional[_Mapping[str, bytes]] = ...) -> None: ...

class ExecuteToolResponse(_message.Message):
    __slots__ = ("success", "result", "error_message", "metadata", "execution_time_ms", "binary_result")
    class MetadataEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: str
        def __init__(self, key: _Optional[str] = ..., value: _Optional[str] = ...) -> None: ...
    SUCCESS_FIELD_NUMBER: _ClassVar[int]
    RESULT_FIELD_NUMBER: _ClassVar[int]
    ERROR_MESSAGE_FIELD_NUMBER: _ClassVar[int]
    METADATA_FIELD_NUMBER: _ClassVar[int]
    EXECUTION_TIME_MS_FIELD_NUMBER: _ClassVar[int]
    BINARY_RESULT_FIELD_NUMBER: _ClassVar[int]
    success: bool
    result: _any_pb2.Any
    error_message: str
    metadata: _containers.ScalarMap[str, str]
    execution_time_ms: int
    binary_result: bytes
    def __init__(self, success: bool = ..., result: _Optional[_Union[_any_pb2.Any, _Mapping]] = ..., error_message: _Optional[str] = ..., metadata: _Optional[_Mapping[str, str]] = ..., execution_time_ms: _Optional[int] = ..., binary_result: _Optional[bytes] = ...) -> None: ...

class ToolChunk(_message.Message):
    __slots__ = ("chunk_id", "data", "is_final", "metadata")
    class MetadataEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: str
        def __init__(self, key: _Optional[str] = ..., value: _Optional[str] = ...) -> None: ...
    CHUNK_ID_FIELD_NUMBER: _ClassVar[int]
    DATA_FIELD_NUMBER: _ClassVar[int]
    IS_FINAL_FIELD_NUMBER: _ClassVar[int]
    METADATA_FIELD_NUMBER: _ClassVar[int]
    chunk_id: str
    data: bytes
    is_final: bool
    metadata: _containers.ScalarMap[str, str]
    def __init__(self, chunk_id: _Optional[str] = ..., data: _Optional[bytes] = ..., is_final: bool = ..., metadata: _Optional[_Mapping[str, str]] = ...) -> None: ...

class GetSessionRequest(_message.Message):
    __slots__ = ("session_id",)
    SESSION_ID_FIELD_NUMBER: _ClassVar[int]
    session_id: str
    def __init__(self, session_id: _Optional[str] = ...) -> None: ...

class GetSessionResponse(_message.Message):
    __slots__ = ("session_id", "metadata", "created_at", "tool_count")
    class MetadataEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: str
        def __init__(self, key: _Optional[str] = ..., value: _Optional[str] = ...) -> None: ...
    SESSION_ID_FIELD_NUMBER: _ClassVar[int]
    METADATA_FIELD_NUMBER: _ClassVar[int]
    CREATED_AT_FIELD_NUMBER: _ClassVar[int]
    TOOL_COUNT_FIELD_NUMBER: _ClassVar[int]
    session_id: str
    metadata: _containers.ScalarMap[str, str]
    created_at: _timestamp_pb2.Timestamp
    tool_count: int
    def __init__(self, session_id: _Optional[str] = ..., metadata: _Optional[_Mapping[str, str]] = ..., created_at: _Optional[_Union[datetime.datetime, _timestamp_pb2.Timestamp, _Mapping]] = ..., tool_count: _Optional[int] = ...) -> None: ...

class HeartbeatRequest(_message.Message):
    __slots__ = ("session_id", "client_time")
    SESSION_ID_FIELD_NUMBER: _ClassVar[int]
    CLIENT_TIME_FIELD_NUMBER: _ClassVar[int]
    session_id: str
    client_time: _timestamp_pb2.Timestamp
    def __init__(self, session_id: _Optional[str] = ..., client_time: _Optional[_Union[datetime.datetime, _timestamp_pb2.Timestamp, _Mapping]] = ...) -> None: ...

class HeartbeatResponse(_message.Message):
    __slots__ = ("server_time", "session_valid")
    SERVER_TIME_FIELD_NUMBER: _ClassVar[int]
    SESSION_VALID_FIELD_NUMBER: _ClassVar[int]
    server_time: _timestamp_pb2.Timestamp
    session_valid: bool
    def __init__(self, server_time: _Optional[_Union[datetime.datetime, _timestamp_pb2.Timestamp, _Mapping]] = ..., session_valid: bool = ...) -> None: ...

class RegisterToolsRequest(_message.Message):
    __slots__ = ("session_id", "tools", "worker_id")
    SESSION_ID_FIELD_NUMBER: _ClassVar[int]
    TOOLS_FIELD_NUMBER: _ClassVar[int]
    WORKER_ID_FIELD_NUMBER: _ClassVar[int]
    session_id: str
    tools: _containers.RepeatedCompositeFieldContainer[ToolRegistration]
    worker_id: str
    def __init__(self, session_id: _Optional[str] = ..., tools: _Optional[_Iterable[_Union[ToolRegistration, _Mapping]]] = ..., worker_id: _Optional[str] = ...) -> None: ...

class ToolRegistration(_message.Message):
    __slots__ = ("name", "description", "parameters", "metadata", "supports_streaming")
    class MetadataEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: str
        def __init__(self, key: _Optional[str] = ..., value: _Optional[str] = ...) -> None: ...
    NAME_FIELD_NUMBER: _ClassVar[int]
    DESCRIPTION_FIELD_NUMBER: _ClassVar[int]
    PARAMETERS_FIELD_NUMBER: _ClassVar[int]
    METADATA_FIELD_NUMBER: _ClassVar[int]
    SUPPORTS_STREAMING_FIELD_NUMBER: _ClassVar[int]
    name: str
    description: str
    parameters: _containers.RepeatedCompositeFieldContainer[ParameterSpec]
    metadata: _containers.ScalarMap[str, str]
    supports_streaming: bool
    def __init__(self, name: _Optional[str] = ..., description: _Optional[str] = ..., parameters: _Optional[_Iterable[_Union[ParameterSpec, _Mapping]]] = ..., metadata: _Optional[_Mapping[str, str]] = ..., supports_streaming: bool = ...) -> None: ...

class RegisterToolsResponse(_message.Message):
    __slots__ = ("success", "tool_ids", "error_message")
    class ToolIdsEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: str
        def __init__(self, key: _Optional[str] = ..., value: _Optional[str] = ...) -> None: ...
    SUCCESS_FIELD_NUMBER: _ClassVar[int]
    TOOL_IDS_FIELD_NUMBER: _ClassVar[int]
    ERROR_MESSAGE_FIELD_NUMBER: _ClassVar[int]
    success: bool
    tool_ids: _containers.ScalarMap[str, str]
    error_message: str
    def __init__(self, success: bool = ..., tool_ids: _Optional[_Mapping[str, str]] = ..., error_message: _Optional[str] = ...) -> None: ...

class GetExposedElixirToolsRequest(_message.Message):
    __slots__ = ("session_id",)
    SESSION_ID_FIELD_NUMBER: _ClassVar[int]
    session_id: str
    def __init__(self, session_id: _Optional[str] = ...) -> None: ...

class GetExposedElixirToolsResponse(_message.Message):
    __slots__ = ("tools",)
    TOOLS_FIELD_NUMBER: _ClassVar[int]
    tools: _containers.RepeatedCompositeFieldContainer[ToolSpec]
    def __init__(self, tools: _Optional[_Iterable[_Union[ToolSpec, _Mapping]]] = ...) -> None: ...

class ExecuteElixirToolRequest(_message.Message):
    __slots__ = ("session_id", "tool_name", "parameters", "metadata")
    class ParametersEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: _any_pb2.Any
        def __init__(self, key: _Optional[str] = ..., value: _Optional[_Union[_any_pb2.Any, _Mapping]] = ...) -> None: ...
    class MetadataEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: str
        def __init__(self, key: _Optional[str] = ..., value: _Optional[str] = ...) -> None: ...
    SESSION_ID_FIELD_NUMBER: _ClassVar[int]
    TOOL_NAME_FIELD_NUMBER: _ClassVar[int]
    PARAMETERS_FIELD_NUMBER: _ClassVar[int]
    METADATA_FIELD_NUMBER: _ClassVar[int]
    session_id: str
    tool_name: str
    parameters: _containers.MessageMap[str, _any_pb2.Any]
    metadata: _containers.ScalarMap[str, str]
    def __init__(self, session_id: _Optional[str] = ..., tool_name: _Optional[str] = ..., parameters: _Optional[_Mapping[str, _any_pb2.Any]] = ..., metadata: _Optional[_Mapping[str, str]] = ...) -> None: ...

class ExecuteElixirToolResponse(_message.Message):
    __slots__ = ("success", "result", "error_message", "metadata", "execution_time_ms", "binary_result")
    class MetadataEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: str
        def __init__(self, key: _Optional[str] = ..., value: _Optional[str] = ...) -> None: ...
    SUCCESS_FIELD_NUMBER: _ClassVar[int]
    RESULT_FIELD_NUMBER: _ClassVar[int]
    ERROR_MESSAGE_FIELD_NUMBER: _ClassVar[int]
    METADATA_FIELD_NUMBER: _ClassVar[int]
    EXECUTION_TIME_MS_FIELD_NUMBER: _ClassVar[int]
    BINARY_RESULT_FIELD_NUMBER: _ClassVar[int]
    success: bool
    result: _any_pb2.Any
    error_message: str
    metadata: _containers.ScalarMap[str, str]
    execution_time_ms: int
    binary_result: bytes
    def __init__(self, success: bool = ..., result: _Optional[_Union[_any_pb2.Any, _Mapping]] = ..., error_message: _Optional[str] = ..., metadata: _Optional[_Mapping[str, str]] = ..., execution_time_ms: _Optional[int] = ..., binary_result: _Optional[bytes] = ...) -> None: ...

class TelemetryEvent(_message.Message):
    __slots__ = ("event_parts", "measurements", "metadata", "timestamp_ns", "correlation_id")
    class MeasurementsEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: TelemetryValue
        def __init__(self, key: _Optional[str] = ..., value: _Optional[_Union[TelemetryValue, _Mapping]] = ...) -> None: ...
    class MetadataEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: str
        def __init__(self, key: _Optional[str] = ..., value: _Optional[str] = ...) -> None: ...
    EVENT_PARTS_FIELD_NUMBER: _ClassVar[int]
    MEASUREMENTS_FIELD_NUMBER: _ClassVar[int]
    METADATA_FIELD_NUMBER: _ClassVar[int]
    TIMESTAMP_NS_FIELD_NUMBER: _ClassVar[int]
    CORRELATION_ID_FIELD_NUMBER: _ClassVar[int]
    event_parts: _containers.RepeatedScalarFieldContainer[str]
    measurements: _containers.MessageMap[str, TelemetryValue]
    metadata: _containers.ScalarMap[str, str]
    timestamp_ns: int
    correlation_id: str
    def __init__(self, event_parts: _Optional[_Iterable[str]] = ..., measurements: _Optional[_Mapping[str, TelemetryValue]] = ..., metadata: _Optional[_Mapping[str, str]] = ..., timestamp_ns: _Optional[int] = ..., correlation_id: _Optional[str] = ...) -> None: ...

class TelemetryValue(_message.Message):
    __slots__ = ("int_value", "float_value", "string_value")
    INT_VALUE_FIELD_NUMBER: _ClassVar[int]
    FLOAT_VALUE_FIELD_NUMBER: _ClassVar[int]
    STRING_VALUE_FIELD_NUMBER: _ClassVar[int]
    int_value: int
    float_value: float
    string_value: str
    def __init__(self, int_value: _Optional[int] = ..., float_value: _Optional[float] = ..., string_value: _Optional[str] = ...) -> None: ...

class TelemetryControl(_message.Message):
    __slots__ = ("toggle", "sampling", "filter")
    TOGGLE_FIELD_NUMBER: _ClassVar[int]
    SAMPLING_FIELD_NUMBER: _ClassVar[int]
    FILTER_FIELD_NUMBER: _ClassVar[int]
    toggle: TelemetryToggle
    sampling: TelemetrySamplingUpdate
    filter: TelemetryEventFilter
    def __init__(self, toggle: _Optional[_Union[TelemetryToggle, _Mapping]] = ..., sampling: _Optional[_Union[TelemetrySamplingUpdate, _Mapping]] = ..., filter: _Optional[_Union[TelemetryEventFilter, _Mapping]] = ...) -> None: ...

class TelemetryToggle(_message.Message):
    __slots__ = ("enabled",)
    ENABLED_FIELD_NUMBER: _ClassVar[int]
    enabled: bool
    def __init__(self, enabled: bool = ...) -> None: ...

class TelemetrySamplingUpdate(_message.Message):
    __slots__ = ("sampling_rate", "event_patterns")
    SAMPLING_RATE_FIELD_NUMBER: _ClassVar[int]
    EVENT_PATTERNS_FIELD_NUMBER: _ClassVar[int]
    sampling_rate: float
    event_patterns: _containers.RepeatedScalarFieldContainer[str]
    def __init__(self, sampling_rate: _Optional[float] = ..., event_patterns: _Optional[_Iterable[str]] = ...) -> None: ...

class TelemetryEventFilter(_message.Message):
    __slots__ = ("allow", "deny")
    ALLOW_FIELD_NUMBER: _ClassVar[int]
    DENY_FIELD_NUMBER: _ClassVar[int]
    allow: _containers.RepeatedScalarFieldContainer[str]
    deny: _containers.RepeatedScalarFieldContainer[str]
    def __init__(self, allow: _Optional[_Iterable[str]] = ..., deny: _Optional[_Iterable[str]] = ...) -> None: ...
