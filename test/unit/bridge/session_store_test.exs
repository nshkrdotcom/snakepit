defmodule SessionStoreTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Test SessionStore functionality independently of gRPC/pool infrastructure.
  """

  test "SessionStore basic operations" do
    session_id = "test_#{System.unique_integer([:positive])}"

    # Create session
    {:ok, session} = Snakepit.Bridge.SessionStore.create_session(session_id)
    assert session.id == session_id
    assert session.metadata == %{}

    # Get session
    assert {:ok, ^session} = Snakepit.Bridge.SessionStore.get_session(session_id)

    # Update session using update function
    {:ok, updated} =
      Snakepit.Bridge.SessionStore.update_session(session_id, fn session ->
        %{session | metadata: %{foo: "bar"}}
      end)

    assert updated.metadata == %{foo: "bar"}

    # Delete session
    :ok = Snakepit.Bridge.SessionStore.delete_session(session_id)
    assert {:error, :not_found} = Snakepit.Bridge.SessionStore.get_session(session_id)
  end

  test "Session expiration" do
    session_id = "expire_#{System.unique_integer([:positive])}"

    # Create session with very short TTL (0 seconds = immediate expiration)
    {:ok, session} = Snakepit.Bridge.SessionStore.create_session(session_id, ttl: 0)
    assert session.id == session_id

    # Session should exist initially
    assert {:ok, _} = Snakepit.Bridge.SessionStore.get_session(session_id)

    # Wait at least 1 second to ensure time has passed (monotonic time is in seconds)
    Process.sleep(1100)

    # Manually trigger cleanup
    Snakepit.Bridge.SessionStore.cleanup_expired_sessions()

    # Session should now be expired
    assert {:error, :not_found} = Snakepit.Bridge.SessionStore.get_session(session_id)
  end
end
