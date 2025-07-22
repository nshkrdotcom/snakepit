from google.protobuf import any_pb2 as _any_pb2
from google.protobuf import timestamp_pb2 as _timestamp_pb2
from google.protobuf.internal import containers as _containers
from google.protobuf.internal import enum_type_wrapper as _enum_type_wrapper
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
    __slots__ = ("success", "error_message", "available_tools", "initial_variables")
    class AvailableToolsEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: ToolSpec
        def __init__(self, key: _Optional[str] = ..., value: _Optional[_Union[ToolSpec, _Mapping]] = ...) -> None: ...
    class InitialVariablesEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: Variable
        def __init__(self, key: _Optional[str] = ..., value: _Optional[_Union[Variable, _Mapping]] = ...) -> None: ...
    SUCCESS_FIELD_NUMBER: _ClassVar[int]
    ERROR_MESSAGE_FIELD_NUMBER: _ClassVar[int]
    AVAILABLE_TOOLS_FIELD_NUMBER: _ClassVar[int]
    INITIAL_VARIABLES_FIELD_NUMBER: _ClassVar[int]
    success: bool
    error_message: str
    available_tools: _containers.MessageMap[str, ToolSpec]
    initial_variables: _containers.MessageMap[str, Variable]
    def __init__(self, success: bool = ..., error_message: _Optional[str] = ..., available_tools: _Optional[_Mapping[str, ToolSpec]] = ..., initial_variables: _Optional[_Mapping[str, Variable]] = ...) -> None: ...

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

class Variable(_message.Message):
    __slots__ = ("id", "name", "type", "value", "constraints_json", "metadata", "source", "last_updated_at", "version", "access_control_json", "optimization_status")
    class Source(int, metaclass=_enum_type_wrapper.EnumTypeWrapper):
        __slots__ = ()
        ELIXIR: _ClassVar[Variable.Source]
        PYTHON: _ClassVar[Variable.Source]
    ELIXIR: Variable.Source
    PYTHON: Variable.Source
    class MetadataEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: str
        def __init__(self, key: _Optional[str] = ..., value: _Optional[str] = ...) -> None: ...
    ID_FIELD_NUMBER: _ClassVar[int]
    NAME_FIELD_NUMBER: _ClassVar[int]
    TYPE_FIELD_NUMBER: _ClassVar[int]
    VALUE_FIELD_NUMBER: _ClassVar[int]
    CONSTRAINTS_JSON_FIELD_NUMBER: _ClassVar[int]
    METADATA_FIELD_NUMBER: _ClassVar[int]
    SOURCE_FIELD_NUMBER: _ClassVar[int]
    LAST_UPDATED_AT_FIELD_NUMBER: _ClassVar[int]
    VERSION_FIELD_NUMBER: _ClassVar[int]
    ACCESS_CONTROL_JSON_FIELD_NUMBER: _ClassVar[int]
    OPTIMIZATION_STATUS_FIELD_NUMBER: _ClassVar[int]
    id: str
    name: str
    type: str
    value: _any_pb2.Any
    constraints_json: str
    metadata: _containers.ScalarMap[str, str]
    source: Variable.Source
    last_updated_at: _timestamp_pb2.Timestamp
    version: int
    access_control_json: str
    optimization_status: OptimizationStatus
    def __init__(self, id: _Optional[str] = ..., name: _Optional[str] = ..., type: _Optional[str] = ..., value: _Optional[_Union[_any_pb2.Any, _Mapping]] = ..., constraints_json: _Optional[str] = ..., metadata: _Optional[_Mapping[str, str]] = ..., source: _Optional[_Union[Variable.Source, str]] = ..., last_updated_at: _Optional[_Union[datetime.datetime, _timestamp_pb2.Timestamp, _Mapping]] = ..., version: _Optional[int] = ..., access_control_json: _Optional[str] = ..., optimization_status: _Optional[_Union[OptimizationStatus, _Mapping]] = ...) -> None: ...

class OptimizationStatus(_message.Message):
    __slots__ = ("optimizing", "optimizer_id", "started_at")
    OPTIMIZING_FIELD_NUMBER: _ClassVar[int]
    OPTIMIZER_ID_FIELD_NUMBER: _ClassVar[int]
    STARTED_AT_FIELD_NUMBER: _ClassVar[int]
    optimizing: bool
    optimizer_id: str
    started_at: _timestamp_pb2.Timestamp
    def __init__(self, optimizing: bool = ..., optimizer_id: _Optional[str] = ..., started_at: _Optional[_Union[datetime.datetime, _timestamp_pb2.Timestamp, _Mapping]] = ...) -> None: ...

class RegisterVariableRequest(_message.Message):
    __slots__ = ("session_id", "name", "type", "initial_value", "constraints_json", "metadata")
    class MetadataEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: str
        def __init__(self, key: _Optional[str] = ..., value: _Optional[str] = ...) -> None: ...
    SESSION_ID_FIELD_NUMBER: _ClassVar[int]
    NAME_FIELD_NUMBER: _ClassVar[int]
    TYPE_FIELD_NUMBER: _ClassVar[int]
    INITIAL_VALUE_FIELD_NUMBER: _ClassVar[int]
    CONSTRAINTS_JSON_FIELD_NUMBER: _ClassVar[int]
    METADATA_FIELD_NUMBER: _ClassVar[int]
    session_id: str
    name: str
    type: str
    initial_value: _any_pb2.Any
    constraints_json: str
    metadata: _containers.ScalarMap[str, str]
    def __init__(self, session_id: _Optional[str] = ..., name: _Optional[str] = ..., type: _Optional[str] = ..., initial_value: _Optional[_Union[_any_pb2.Any, _Mapping]] = ..., constraints_json: _Optional[str] = ..., metadata: _Optional[_Mapping[str, str]] = ...) -> None: ...

class RegisterVariableResponse(_message.Message):
    __slots__ = ("success", "variable_id", "error_message")
    SUCCESS_FIELD_NUMBER: _ClassVar[int]
    VARIABLE_ID_FIELD_NUMBER: _ClassVar[int]
    ERROR_MESSAGE_FIELD_NUMBER: _ClassVar[int]
    success: bool
    variable_id: str
    error_message: str
    def __init__(self, success: bool = ..., variable_id: _Optional[str] = ..., error_message: _Optional[str] = ...) -> None: ...

class GetVariableRequest(_message.Message):
    __slots__ = ("session_id", "variable_identifier", "bypass_cache")
    SESSION_ID_FIELD_NUMBER: _ClassVar[int]
    VARIABLE_IDENTIFIER_FIELD_NUMBER: _ClassVar[int]
    BYPASS_CACHE_FIELD_NUMBER: _ClassVar[int]
    session_id: str
    variable_identifier: str
    bypass_cache: bool
    def __init__(self, session_id: _Optional[str] = ..., variable_identifier: _Optional[str] = ..., bypass_cache: bool = ...) -> None: ...

class GetVariableResponse(_message.Message):
    __slots__ = ("variable", "from_cache")
    VARIABLE_FIELD_NUMBER: _ClassVar[int]
    FROM_CACHE_FIELD_NUMBER: _ClassVar[int]
    variable: Variable
    from_cache: bool
    def __init__(self, variable: _Optional[_Union[Variable, _Mapping]] = ..., from_cache: bool = ...) -> None: ...

class SetVariableRequest(_message.Message):
    __slots__ = ("session_id", "variable_identifier", "value", "metadata", "expected_version")
    class MetadataEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: str
        def __init__(self, key: _Optional[str] = ..., value: _Optional[str] = ...) -> None: ...
    SESSION_ID_FIELD_NUMBER: _ClassVar[int]
    VARIABLE_IDENTIFIER_FIELD_NUMBER: _ClassVar[int]
    VALUE_FIELD_NUMBER: _ClassVar[int]
    METADATA_FIELD_NUMBER: _ClassVar[int]
    EXPECTED_VERSION_FIELD_NUMBER: _ClassVar[int]
    session_id: str
    variable_identifier: str
    value: _any_pb2.Any
    metadata: _containers.ScalarMap[str, str]
    expected_version: int
    def __init__(self, session_id: _Optional[str] = ..., variable_identifier: _Optional[str] = ..., value: _Optional[_Union[_any_pb2.Any, _Mapping]] = ..., metadata: _Optional[_Mapping[str, str]] = ..., expected_version: _Optional[int] = ...) -> None: ...

class SetVariableResponse(_message.Message):
    __slots__ = ("success", "error_message", "new_version")
    SUCCESS_FIELD_NUMBER: _ClassVar[int]
    ERROR_MESSAGE_FIELD_NUMBER: _ClassVar[int]
    NEW_VERSION_FIELD_NUMBER: _ClassVar[int]
    success: bool
    error_message: str
    new_version: int
    def __init__(self, success: bool = ..., error_message: _Optional[str] = ..., new_version: _Optional[int] = ...) -> None: ...

class BatchGetVariablesRequest(_message.Message):
    __slots__ = ("session_id", "variable_identifiers", "include_metadata", "bypass_cache")
    SESSION_ID_FIELD_NUMBER: _ClassVar[int]
    VARIABLE_IDENTIFIERS_FIELD_NUMBER: _ClassVar[int]
    INCLUDE_METADATA_FIELD_NUMBER: _ClassVar[int]
    BYPASS_CACHE_FIELD_NUMBER: _ClassVar[int]
    session_id: str
    variable_identifiers: _containers.RepeatedScalarFieldContainer[str]
    include_metadata: bool
    bypass_cache: bool
    def __init__(self, session_id: _Optional[str] = ..., variable_identifiers: _Optional[_Iterable[str]] = ..., include_metadata: bool = ..., bypass_cache: bool = ...) -> None: ...

class BatchGetVariablesResponse(_message.Message):
    __slots__ = ("variables", "missing_variables")
    class VariablesEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: Variable
        def __init__(self, key: _Optional[str] = ..., value: _Optional[_Union[Variable, _Mapping]] = ...) -> None: ...
    VARIABLES_FIELD_NUMBER: _ClassVar[int]
    MISSING_VARIABLES_FIELD_NUMBER: _ClassVar[int]
    variables: _containers.MessageMap[str, Variable]
    missing_variables: _containers.RepeatedScalarFieldContainer[str]
    def __init__(self, variables: _Optional[_Mapping[str, Variable]] = ..., missing_variables: _Optional[_Iterable[str]] = ...) -> None: ...

class BatchSetVariablesRequest(_message.Message):
    __slots__ = ("session_id", "updates", "metadata", "atomic")
    class UpdatesEntry(_message.Message):
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
    UPDATES_FIELD_NUMBER: _ClassVar[int]
    METADATA_FIELD_NUMBER: _ClassVar[int]
    ATOMIC_FIELD_NUMBER: _ClassVar[int]
    session_id: str
    updates: _containers.MessageMap[str, _any_pb2.Any]
    metadata: _containers.ScalarMap[str, str]
    atomic: bool
    def __init__(self, session_id: _Optional[str] = ..., updates: _Optional[_Mapping[str, _any_pb2.Any]] = ..., metadata: _Optional[_Mapping[str, str]] = ..., atomic: bool = ...) -> None: ...

class BatchSetVariablesResponse(_message.Message):
    __slots__ = ("success", "errors", "new_versions")
    class ErrorsEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: str
        def __init__(self, key: _Optional[str] = ..., value: _Optional[str] = ...) -> None: ...
    class NewVersionsEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: int
        def __init__(self, key: _Optional[str] = ..., value: _Optional[int] = ...) -> None: ...
    SUCCESS_FIELD_NUMBER: _ClassVar[int]
    ERRORS_FIELD_NUMBER: _ClassVar[int]
    NEW_VERSIONS_FIELD_NUMBER: _ClassVar[int]
    success: bool
    errors: _containers.ScalarMap[str, str]
    new_versions: _containers.ScalarMap[str, int]
    def __init__(self, success: bool = ..., errors: _Optional[_Mapping[str, str]] = ..., new_versions: _Optional[_Mapping[str, int]] = ...) -> None: ...

class ListVariablesRequest(_message.Message):
    __slots__ = ("session_id", "pattern")
    SESSION_ID_FIELD_NUMBER: _ClassVar[int]
    PATTERN_FIELD_NUMBER: _ClassVar[int]
    session_id: str
    pattern: str
    def __init__(self, session_id: _Optional[str] = ..., pattern: _Optional[str] = ...) -> None: ...

class ListVariablesResponse(_message.Message):
    __slots__ = ("variables",)
    VARIABLES_FIELD_NUMBER: _ClassVar[int]
    variables: _containers.RepeatedCompositeFieldContainer[Variable]
    def __init__(self, variables: _Optional[_Iterable[_Union[Variable, _Mapping]]] = ...) -> None: ...

class DeleteVariableRequest(_message.Message):
    __slots__ = ("session_id", "variable_identifier")
    SESSION_ID_FIELD_NUMBER: _ClassVar[int]
    VARIABLE_IDENTIFIER_FIELD_NUMBER: _ClassVar[int]
    session_id: str
    variable_identifier: str
    def __init__(self, session_id: _Optional[str] = ..., variable_identifier: _Optional[str] = ...) -> None: ...

class DeleteVariableResponse(_message.Message):
    __slots__ = ("success", "error_message")
    SUCCESS_FIELD_NUMBER: _ClassVar[int]
    ERROR_MESSAGE_FIELD_NUMBER: _ClassVar[int]
    success: bool
    error_message: str
    def __init__(self, success: bool = ..., error_message: _Optional[str] = ...) -> None: ...

class ToolSpec(_message.Message):
    __slots__ = ("name", "description", "parameters", "metadata", "supports_streaming", "required_variables")
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
    REQUIRED_VARIABLES_FIELD_NUMBER: _ClassVar[int]
    name: str
    description: str
    parameters: _containers.RepeatedCompositeFieldContainer[ParameterSpec]
    metadata: _containers.ScalarMap[str, str]
    supports_streaming: bool
    required_variables: _containers.RepeatedScalarFieldContainer[str]
    def __init__(self, name: _Optional[str] = ..., description: _Optional[str] = ..., parameters: _Optional[_Iterable[_Union[ParameterSpec, _Mapping]]] = ..., metadata: _Optional[_Mapping[str, str]] = ..., supports_streaming: bool = ..., required_variables: _Optional[_Iterable[str]] = ...) -> None: ...

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
    __slots__ = ("session_id", "tool_name", "parameters", "metadata", "stream")
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
    STREAM_FIELD_NUMBER: _ClassVar[int]
    session_id: str
    tool_name: str
    parameters: _containers.MessageMap[str, _any_pb2.Any]
    metadata: _containers.ScalarMap[str, str]
    stream: bool
    def __init__(self, session_id: _Optional[str] = ..., tool_name: _Optional[str] = ..., parameters: _Optional[_Mapping[str, _any_pb2.Any]] = ..., metadata: _Optional[_Mapping[str, str]] = ..., stream: bool = ...) -> None: ...

class ExecuteToolResponse(_message.Message):
    __slots__ = ("success", "result", "error_message", "metadata", "execution_time_ms")
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
    success: bool
    result: _any_pb2.Any
    error_message: str
    metadata: _containers.ScalarMap[str, str]
    execution_time_ms: int
    def __init__(self, success: bool = ..., result: _Optional[_Union[_any_pb2.Any, _Mapping]] = ..., error_message: _Optional[str] = ..., metadata: _Optional[_Mapping[str, str]] = ..., execution_time_ms: _Optional[int] = ...) -> None: ...

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

class WatchVariablesRequest(_message.Message):
    __slots__ = ("session_id", "variable_identifiers", "include_initial_values")
    SESSION_ID_FIELD_NUMBER: _ClassVar[int]
    VARIABLE_IDENTIFIERS_FIELD_NUMBER: _ClassVar[int]
    INCLUDE_INITIAL_VALUES_FIELD_NUMBER: _ClassVar[int]
    session_id: str
    variable_identifiers: _containers.RepeatedScalarFieldContainer[str]
    include_initial_values: bool
    def __init__(self, session_id: _Optional[str] = ..., variable_identifiers: _Optional[_Iterable[str]] = ..., include_initial_values: bool = ...) -> None: ...

class VariableUpdate(_message.Message):
    __slots__ = ("variable_id", "variable", "update_source", "update_metadata", "timestamp", "update_type")
    class UpdateMetadataEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: str
        def __init__(self, key: _Optional[str] = ..., value: _Optional[str] = ...) -> None: ...
    VARIABLE_ID_FIELD_NUMBER: _ClassVar[int]
    VARIABLE_FIELD_NUMBER: _ClassVar[int]
    UPDATE_SOURCE_FIELD_NUMBER: _ClassVar[int]
    UPDATE_METADATA_FIELD_NUMBER: _ClassVar[int]
    TIMESTAMP_FIELD_NUMBER: _ClassVar[int]
    UPDATE_TYPE_FIELD_NUMBER: _ClassVar[int]
    variable_id: str
    variable: Variable
    update_source: str
    update_metadata: _containers.ScalarMap[str, str]
    timestamp: _timestamp_pb2.Timestamp
    update_type: str
    def __init__(self, variable_id: _Optional[str] = ..., variable: _Optional[_Union[Variable, _Mapping]] = ..., update_source: _Optional[str] = ..., update_metadata: _Optional[_Mapping[str, str]] = ..., timestamp: _Optional[_Union[datetime.datetime, _timestamp_pb2.Timestamp, _Mapping]] = ..., update_type: _Optional[str] = ...) -> None: ...

class AddDependencyRequest(_message.Message):
    __slots__ = ("session_id", "from_variable", "to_variable", "dependency_type")
    SESSION_ID_FIELD_NUMBER: _ClassVar[int]
    FROM_VARIABLE_FIELD_NUMBER: _ClassVar[int]
    TO_VARIABLE_FIELD_NUMBER: _ClassVar[int]
    DEPENDENCY_TYPE_FIELD_NUMBER: _ClassVar[int]
    session_id: str
    from_variable: str
    to_variable: str
    dependency_type: str
    def __init__(self, session_id: _Optional[str] = ..., from_variable: _Optional[str] = ..., to_variable: _Optional[str] = ..., dependency_type: _Optional[str] = ...) -> None: ...

class AddDependencyResponse(_message.Message):
    __slots__ = ("success", "error_message")
    SUCCESS_FIELD_NUMBER: _ClassVar[int]
    ERROR_MESSAGE_FIELD_NUMBER: _ClassVar[int]
    success: bool
    error_message: str
    def __init__(self, success: bool = ..., error_message: _Optional[str] = ...) -> None: ...

class StartOptimizationRequest(_message.Message):
    __slots__ = ("session_id", "variable_identifier", "optimizer_id", "optimizer_config")
    class OptimizerConfigEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: str
        def __init__(self, key: _Optional[str] = ..., value: _Optional[str] = ...) -> None: ...
    SESSION_ID_FIELD_NUMBER: _ClassVar[int]
    VARIABLE_IDENTIFIER_FIELD_NUMBER: _ClassVar[int]
    OPTIMIZER_ID_FIELD_NUMBER: _ClassVar[int]
    OPTIMIZER_CONFIG_FIELD_NUMBER: _ClassVar[int]
    session_id: str
    variable_identifier: str
    optimizer_id: str
    optimizer_config: _containers.ScalarMap[str, str]
    def __init__(self, session_id: _Optional[str] = ..., variable_identifier: _Optional[str] = ..., optimizer_id: _Optional[str] = ..., optimizer_config: _Optional[_Mapping[str, str]] = ...) -> None: ...

class StartOptimizationResponse(_message.Message):
    __slots__ = ("success", "error_message", "optimization_id")
    SUCCESS_FIELD_NUMBER: _ClassVar[int]
    ERROR_MESSAGE_FIELD_NUMBER: _ClassVar[int]
    OPTIMIZATION_ID_FIELD_NUMBER: _ClassVar[int]
    success: bool
    error_message: str
    optimization_id: str
    def __init__(self, success: bool = ..., error_message: _Optional[str] = ..., optimization_id: _Optional[str] = ...) -> None: ...

class StopOptimizationRequest(_message.Message):
    __slots__ = ("session_id", "variable_identifier", "force")
    SESSION_ID_FIELD_NUMBER: _ClassVar[int]
    VARIABLE_IDENTIFIER_FIELD_NUMBER: _ClassVar[int]
    FORCE_FIELD_NUMBER: _ClassVar[int]
    session_id: str
    variable_identifier: str
    force: bool
    def __init__(self, session_id: _Optional[str] = ..., variable_identifier: _Optional[str] = ..., force: bool = ...) -> None: ...

class StopOptimizationResponse(_message.Message):
    __slots__ = ("success", "final_value")
    SUCCESS_FIELD_NUMBER: _ClassVar[int]
    FINAL_VALUE_FIELD_NUMBER: _ClassVar[int]
    success: bool
    final_value: _any_pb2.Any
    def __init__(self, success: bool = ..., final_value: _Optional[_Union[_any_pb2.Any, _Mapping]] = ...) -> None: ...

class GetVariableHistoryRequest(_message.Message):
    __slots__ = ("session_id", "variable_identifier", "limit")
    SESSION_ID_FIELD_NUMBER: _ClassVar[int]
    VARIABLE_IDENTIFIER_FIELD_NUMBER: _ClassVar[int]
    LIMIT_FIELD_NUMBER: _ClassVar[int]
    session_id: str
    variable_identifier: str
    limit: int
    def __init__(self, session_id: _Optional[str] = ..., variable_identifier: _Optional[str] = ..., limit: _Optional[int] = ...) -> None: ...

class GetVariableHistoryResponse(_message.Message):
    __slots__ = ("entries",)
    ENTRIES_FIELD_NUMBER: _ClassVar[int]
    entries: _containers.RepeatedCompositeFieldContainer[VariableHistoryEntry]
    def __init__(self, entries: _Optional[_Iterable[_Union[VariableHistoryEntry, _Mapping]]] = ...) -> None: ...

class VariableHistoryEntry(_message.Message):
    __slots__ = ("version", "value", "timestamp", "changed_by", "metadata")
    class MetadataEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: str
        def __init__(self, key: _Optional[str] = ..., value: _Optional[str] = ...) -> None: ...
    VERSION_FIELD_NUMBER: _ClassVar[int]
    VALUE_FIELD_NUMBER: _ClassVar[int]
    TIMESTAMP_FIELD_NUMBER: _ClassVar[int]
    CHANGED_BY_FIELD_NUMBER: _ClassVar[int]
    METADATA_FIELD_NUMBER: _ClassVar[int]
    version: int
    value: _any_pb2.Any
    timestamp: _timestamp_pb2.Timestamp
    changed_by: str
    metadata: _containers.ScalarMap[str, str]
    def __init__(self, version: _Optional[int] = ..., value: _Optional[_Union[_any_pb2.Any, _Mapping]] = ..., timestamp: _Optional[_Union[datetime.datetime, _timestamp_pb2.Timestamp, _Mapping]] = ..., changed_by: _Optional[str] = ..., metadata: _Optional[_Mapping[str, str]] = ...) -> None: ...

class RollbackVariableRequest(_message.Message):
    __slots__ = ("session_id", "variable_identifier", "target_version")
    SESSION_ID_FIELD_NUMBER: _ClassVar[int]
    VARIABLE_IDENTIFIER_FIELD_NUMBER: _ClassVar[int]
    TARGET_VERSION_FIELD_NUMBER: _ClassVar[int]
    session_id: str
    variable_identifier: str
    target_version: int
    def __init__(self, session_id: _Optional[str] = ..., variable_identifier: _Optional[str] = ..., target_version: _Optional[int] = ...) -> None: ...

class RollbackVariableResponse(_message.Message):
    __slots__ = ("success", "variable", "error_message")
    SUCCESS_FIELD_NUMBER: _ClassVar[int]
    VARIABLE_FIELD_NUMBER: _ClassVar[int]
    ERROR_MESSAGE_FIELD_NUMBER: _ClassVar[int]
    success: bool
    variable: Variable
    error_message: str
    def __init__(self, success: bool = ..., variable: _Optional[_Union[Variable, _Mapping]] = ..., error_message: _Optional[str] = ...) -> None: ...

class GetSessionRequest(_message.Message):
    __slots__ = ("session_id",)
    SESSION_ID_FIELD_NUMBER: _ClassVar[int]
    session_id: str
    def __init__(self, session_id: _Optional[str] = ...) -> None: ...

class GetSessionResponse(_message.Message):
    __slots__ = ("session_id", "metadata", "created_at", "variable_count", "tool_count")
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
    VARIABLE_COUNT_FIELD_NUMBER: _ClassVar[int]
    TOOL_COUNT_FIELD_NUMBER: _ClassVar[int]
    session_id: str
    metadata: _containers.ScalarMap[str, str]
    created_at: _timestamp_pb2.Timestamp
    variable_count: int
    tool_count: int
    def __init__(self, session_id: _Optional[str] = ..., metadata: _Optional[_Mapping[str, str]] = ..., created_at: _Optional[_Union[datetime.datetime, _timestamp_pb2.Timestamp, _Mapping]] = ..., variable_count: _Optional[int] = ..., tool_count: _Optional[int] = ...) -> None: ...

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
