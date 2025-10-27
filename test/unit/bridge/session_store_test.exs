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

  test "enforces session quota and respects cleanup" do
    server_name = :session_store_quota_server

    start_supervised!(
      {Snakepit.Bridge.SessionStore,
       name: server_name, table_name: :session_store_quota_table, max_sessions: 1}
    )

    assert {:ok, _} = Snakepit.Bridge.SessionStore.create_session(server_name, "s1", ttl: 0)

    assert {:error, :session_quota_exceeded} =
             Snakepit.Bridge.SessionStore.create_session(server_name, "s2", [])

    assert_eventually(
      fn ->
        Snakepit.Bridge.SessionStore.cleanup_expired_sessions(server_name) > 0
      end,
      timeout: 2_000,
      interval: 50
    )

    assert {:ok, _} = Snakepit.Bridge.SessionStore.create_session(server_name, "s2", ttl: 0)
  end

  test "enforces per-session program quota" do
    server_name = :session_store_program_quota

    start_supervised!(
      {Snakepit.Bridge.SessionStore,
       name: server_name, table_name: :session_store_program_table, max_programs_per_session: 1}
    )

    session_id = "quota_session_#{System.unique_integer([:positive])}"
    assert {:ok, _} = Snakepit.Bridge.SessionStore.create_session(server_name, session_id, [])

    assert :ok =
             Snakepit.Bridge.SessionStore.store_program(server_name, session_id, "prog1", %{})

    assert {:error, {:program_quota_exceeded, ^session_id}} =
             Snakepit.Bridge.SessionStore.store_program(server_name, session_id, "prog2", %{})

    # Updating existing program is allowed under the quota
    assert :ok =
             Snakepit.Bridge.SessionStore.store_program(server_name, session_id, "prog1", %{
               "version" => 2
             })
  end

  test "enforces global program quota" do
    server_name = :session_store_global_quota

    start_supervised!(
      {Snakepit.Bridge.SessionStore,
       name: server_name, table_name: :session_store_global_table, max_global_programs: 1}
    )

    assert :ok = Snakepit.Bridge.SessionStore.store_global_program(server_name, "prog1", %{})

    assert {:error, :global_program_quota_exceeded} =
             Snakepit.Bridge.SessionStore.store_global_program(server_name, "prog2", %{})

    :ok = Snakepit.Bridge.SessionStore.delete_global_program(server_name, "prog1")

    assert :ok = Snakepit.Bridge.SessionStore.store_global_program(server_name, "prog2", %{})
  end
end
