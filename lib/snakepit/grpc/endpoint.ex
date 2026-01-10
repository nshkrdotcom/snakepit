defmodule Snakepit.GRPC.Endpoint do
  @moduledoc """
  gRPC endpoint for the Snakepit bridge server.

  This module defines the gRPC endpoint that handles incoming
  requests for the unified bridge protocol.
  """

  use GRPC.Endpoint

  intercept(Snakepit.GRPC.Interceptors.ServerLogger, level: :info)
  run(Snakepit.GRPC.BridgeServer)
end
