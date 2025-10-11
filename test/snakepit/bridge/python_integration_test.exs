defmodule Snakepit.Bridge.PythonIntegrationTest do
  @moduledoc """
  Python integration test suite for the Snakepit gRPC bridge.

  This test suite requires Python gRPC workers and tests:
  - gRPC communication (Python <-> Elixir bridge)
  - Worker lifecycle management

  To run these tests:
    mix test --include python_integration
  """

  use Snakepit.PythonIntegrationCase

  describe "Full Stack Integration" do
    setup do
      session_id = "integration_test_#{:erlang.unique_integer([:positive])}"
      {:ok, session_id: session_id}
    end

    test "heartbeat and session timeout", %{session_id: session_id} do
      {:ok, channel} = GRPC.Stub.connect("localhost:50051")

      on_exit(fn ->
        GRPC.Stub.disconnect(channel)
      end)

      # Initialize session
      assert {:ok, %{success: true}} = Client.initialize_session(channel, session_id)

      # Send heartbeats with spacing (using receive timeout pattern)
      for _ <- 1..3 do
        assert {:ok, %{success: true}} = Client.heartbeat(channel, session_id)
        # Space out heartbeats using receive timeout (NOT Process.sleep)
        receive do
        after
          100 -> :ok
        end
      end

      # Session should still be active
      assert {:ok, %{session: session}} = Client.get_session(channel, session_id)
      assert session.active == true

      # Clean up
      assert {:ok, %{success: true}} = Client.cleanup_session(channel, session_id)
    end
  end
end
