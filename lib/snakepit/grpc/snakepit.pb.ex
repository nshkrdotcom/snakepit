# Map entry definitions must come first
defmodule Snakepit.Grpc.ExecuteRequest.ArgsEntry do
  @moduledoc false
  use Protobuf, map: true, syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :bytes)
end

defmodule Snakepit.Grpc.ExecuteResponse.ResultEntry do
  @moduledoc false
  use Protobuf, map: true, syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :bytes)
end

defmodule Snakepit.Grpc.StreamResponse.ChunkEntry do
  @moduledoc false
  use Protobuf, map: true, syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :bytes)
end

defmodule Snakepit.Grpc.SessionRequest.ArgsEntry do
  @moduledoc false
  use Protobuf, map: true, syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :bytes)
end

defmodule Snakepit.Grpc.InfoResponse.CapabilitiesEntry do
  @moduledoc false
  use Protobuf, map: true, syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

defmodule Snakepit.Grpc.InfoResponse.SystemInfoEntry do
  @moduledoc false
  use Protobuf, map: true, syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

# Main message definitions
defmodule Snakepit.Grpc.ExecuteRequest do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:command, 1, type: :string)
  field(:args, 2, repeated: true, type: Snakepit.Grpc.ExecuteRequest.ArgsEntry, map: true)
  field(:timeout_ms, 3, type: :int32)
  field(:request_id, 4, type: :string)
end

defmodule Snakepit.Grpc.ExecuteResponse do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:success, 1, type: :bool)
  field(:result, 2, repeated: true, type: Snakepit.Grpc.ExecuteResponse.ResultEntry, map: true)
  field(:error, 3, type: :string)
  field(:timestamp, 4, type: :int64)
  field(:request_id, 5, type: :string)
end

defmodule Snakepit.Grpc.StreamResponse do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:is_final, 1, type: :bool)
  field(:chunk, 2, repeated: true, type: Snakepit.Grpc.StreamResponse.ChunkEntry, map: true)
  field(:error, 3, type: :string)
  field(:timestamp, 4, type: :int64)
  field(:request_id, 5, type: :string)
  field(:chunk_index, 6, type: :int32)
end

defmodule Snakepit.Grpc.SessionRequest do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:session_id, 1, type: :string)
  field(:command, 2, type: :string)
  field(:args, 3, repeated: true, type: Snakepit.Grpc.SessionRequest.ArgsEntry, map: true)
  field(:timeout_ms, 4, type: :int32)
  field(:request_id, 5, type: :string)
end

defmodule Snakepit.Grpc.HealthRequest do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:worker_id, 1, type: :string)
end

defmodule Snakepit.Grpc.HealthResponse do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:healthy, 1, type: :bool)
  field(:worker_id, 2, type: :string)
  field(:uptime_ms, 3, type: :int64)
  field(:total_requests, 4, type: :int64)
  field(:total_errors, 5, type: :int64)
  field(:version, 6, type: :string)
end

defmodule Snakepit.Grpc.InfoRequest do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:include_capabilities, 1, type: :bool)
  field(:include_stats, 2, type: :bool)
end

defmodule Snakepit.Grpc.WorkerStats do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:requests_handled, 1, type: :int64)
  field(:requests_failed, 2, type: :int64)
  field(:uptime_ms, 3, type: :int64)
  field(:memory_usage_bytes, 4, type: :int64)
  field(:cpu_usage_percent, 5, type: :double)
  field(:active_sessions, 6, type: :int64)
end

defmodule Snakepit.Grpc.InfoResponse do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:worker_type, 1, type: :string)
  field(:version, 2, type: :string)
  field(:supported_commands, 3, repeated: true, type: :string)

  field(:capabilities, 4,
    repeated: true,
    type: Snakepit.Grpc.InfoResponse.CapabilitiesEntry,
    map: true
  )

  field(:stats, 5, type: Snakepit.Grpc.WorkerStats)

  field(:system_info, 6,
    repeated: true,
    type: Snakepit.Grpc.InfoResponse.SystemInfoEntry,
    map: true
  )
end
