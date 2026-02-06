defmodule Snakepit.Telemetry.GrpcStreamTest do
  use ExUnit.Case, async: true

  alias Snakepit.Telemetry.GrpcStream

  test "list_streams tolerates :noproc exits and returns empty list" do
    assert [] ==
             GrpcStream.list_streams(fn ->
               exit({:noproc, {GenServer, :call, [GrpcStream, :list_streams]}})
             end)
  end
end
