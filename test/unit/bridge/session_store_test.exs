defmodule SessionStoreTest do
  use ExUnit.Case, async: true
  import Snakepit.TestHelpers

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

    # Poll until session expires (using Supertester pattern)
    # Run cleanup and check if session is gone
    assert_eventually(
      fn ->
        Snakepit.Bridge.SessionStore.cleanup_expired_sessions()
        match?({:error, :not_found}, Snakepit.Bridge.SessionStore.get_session(session_id))
      end,
      timeout: 2_000,
      interval: 50
    )
  end

  test "rejects direct ETS writes from external processes" do
    session_id = "direct_write_#{System.unique_integer([:positive])}"

    {:ok, _session} = Snakepit.Bridge.SessionStore.create_session(session_id)

    assert_raise ArgumentError, fn ->
      :ets.insert(:snakepit_sessions, {session_id <> "_evil", {0, 0, %{}}})
    end
  end
end
