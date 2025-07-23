defmodule GRPCSimpleTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Simple test to verify gRPC components work without full pool infrastructure.
  This helps isolate gRPC-specific issues from pool management issues.
  """

  require Logger

  setup_all do
    # SessionStore is already started by the application
    # Just ensure the gRPC server is available
    case GRPC.Server.Supervisor.start_link(
           endpoint: Snakepit.GRPC.Endpoint,
           port: 50051,
           start_server: true
         ) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Give the server time to start
    Process.sleep(500)

    :ok
  end

  test "Elixir gRPC server is accessible" do
    # Try to connect to the gRPC server
    {:ok, channel} = GRPC.Stub.connect("localhost:50051")
    assert channel != nil

    # The channel should be a valid reference
    assert is_reference(channel) or is_pid(channel) or is_port(channel)
  end

  test "SessionStore can manage sessions" do
    session_id = "test_session_#{System.unique_integer([:positive])}"

    # Create session
    {:ok, session} = Snakepit.Bridge.SessionStore.create_session(session_id)
    assert session.id == session_id

    # Get session
    assert {:ok, ^session} = Snakepit.Bridge.SessionStore.get_session(session_id)

    # Get session again to verify it exists
    assert {:ok, _} = Snakepit.Bridge.SessionStore.get_session(session_id)

    # Delete session
    :ok = Snakepit.Bridge.SessionStore.delete_session(session_id)
    assert {:error, :not_found} = Snakepit.Bridge.SessionStore.get_session(session_id)
  end

  test "SessionStore can manage variables" do
    session_id = "var_test_#{System.unique_integer([:positive])}"
    {:ok, _} = Snakepit.Bridge.SessionStore.create_session(session_id)

    # Register variable with correct API
    {:ok, var_id} =
      Snakepit.Bridge.SessionStore.register_variable(
        session_id,
        "test_var",
        :integer,
        42,
        constraints: %{min: 0, max: 100}
      )

    assert is_binary(var_id)

    # Get variable
    {:ok, var} = Snakepit.Bridge.SessionStore.get_variable(session_id, "test_var")
    assert var.name == "test_var"
    assert var.value == 42

    # Update variable
    {:ok, updated} = Snakepit.Bridge.SessionStore.update_variable(session_id, "test_var", 50)
    assert updated.value == 50

    # List variables
    {:ok, vars} = Snakepit.Bridge.SessionStore.list_variables(session_id)
    assert length(vars) == 1
    assert hd(vars).name == "test_var"

    # Cleanup
    Snakepit.Bridge.SessionStore.delete_session(session_id)
  end
end
