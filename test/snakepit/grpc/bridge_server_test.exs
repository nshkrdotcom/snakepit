defmodule Snakepit.GRPC.BridgeServerTest do
  use ExUnit.Case, async: false

  alias Snakepit.Bridge.SessionStore
  alias Snakepit.GRPC.BridgeServer

  alias Snakepit.Bridge.{
    PingRequest,
    PingResponse,
    InitializeSessionRequest,
    InitializeSessionResponse
  }

  alias Google.Protobuf.Timestamp

  setup do
    # Start SessionStore
    case SessionStore.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Create test session
    session_id = "test_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      # Best effort cleanup - SessionStore may already be stopped
      try do
        SessionStore.delete_session(session_id)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, session_id: session_id}
  end

  describe "ping/2" do
    test "responds with pong" do
      request = %PingRequest{message: "hello"}
      response = BridgeServer.ping(request, nil)

      assert %PingResponse{} = response
      assert response.message == "pong: hello"
      assert %Timestamp{} = response.server_time
    end
  end

  describe "initialize_session/2" do
    test "creates new session", %{session_id: session_id} do
      request = %InitializeSessionRequest{
        session_id: session_id,
        metadata: %{"source" => "test"}
      }

      response = BridgeServer.initialize_session(request, nil)

      assert %InitializeSessionResponse{} = response
      assert response.success == true
      assert response.error_message == nil
    end

    test "handles duplicate session gracefully", %{session_id: session_id} do
      # First create
      {:ok, _} = SessionStore.create_session(session_id)

      request = %InitializeSessionRequest{
        session_id: session_id,
        metadata: %{}
      }

      # Duplicate init should succeed (idempotent operation)
      response = BridgeServer.initialize_session(request, nil)
      assert response.success == true

      # Session should still exist and be usable
      assert {:ok, _session} = SessionStore.get_session(session_id)
    end
  end
end
