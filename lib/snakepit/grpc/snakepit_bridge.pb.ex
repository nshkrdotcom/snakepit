defmodule Snakepit.Grpc.SnakepitBridge.Service do
  @moduledoc false
  use GRPC.Service, name: "snakepit.SnakepitBridge"

  alias Snakepit.Grpc.{
    ExecuteRequest,
    ExecuteResponse,
    StreamResponse,
    SessionRequest,
    HealthRequest,
    HealthResponse,
    InfoRequest,
    InfoResponse
  }

  rpc(:Execute, ExecuteRequest, ExecuteResponse)
  rpc(:ExecuteStream, ExecuteRequest, stream(StreamResponse))
  rpc(:ExecuteInSession, SessionRequest, ExecuteResponse)
  rpc(:ExecuteInSessionStream, SessionRequest, stream(StreamResponse))
  rpc(:Health, HealthRequest, HealthResponse)
  rpc(:GetInfo, InfoRequest, InfoResponse)
end

defmodule Snakepit.Grpc.SnakepitBridge.Stub do
  @moduledoc false
  use GRPC.Stub, service: Snakepit.Grpc.SnakepitBridge.Service
end
