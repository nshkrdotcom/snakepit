defmodule SessionStoreTest do
  use ExUnit.Case, async: true
  import Snakepit.TestHelpers

  alias Snakepit.Bridge.SessionStore

  @moduledoc """
  Test SessionStore functionality independently of gRPC/pool infrastructure.
  """

  test "SessionStore basic operations" do
    session_id = "test_#{System.unique_integer([:positive])}"

    # Create session
    {:ok, session} = SessionStore.create_session(session_id)
    assert session.id == session_id
    assert session.metadata == %{}

    # Get session
    assert {:ok, ^session} = SessionStore.get_session(session_id)

    # Update session using update function
    {:ok, updated} =
      SessionStore.update_session(session_id, fn session ->
        %{session | metadata: %{foo: "bar"}}
      end)

    assert updated.metadata == %{foo: "bar"}

    # Delete session
    :ok = SessionStore.delete_session(session_id)
    assert {:error, :not_found} = SessionStore.get_session(session_id)
  end

  test "Session expiration" do
    session_id = "expire_#{System.unique_integer([:positive])}"

    # Create session with very short TTL (0 seconds = immediate expiration)
    {:ok, session} = SessionStore.create_session(session_id, ttl: 0)
    assert session.id == session_id

    # Session should exist initially
    assert {:ok, _} = SessionStore.get_session(session_id)

    # Poll until session expires (using Supertester pattern)
    # Run cleanup and check if session is gone
    assert_eventually(
      fn ->
        SessionStore.cleanup_expired_sessions()
        match?({:error, :not_found}, SessionStore.get_session(session_id))
      end,
      timeout: 1_200,
      interval: 10
    )
  end

  test "rejects direct ETS writes from external processes" do
    session_id = "direct_write_#{System.unique_integer([:positive])}"

    {:ok, _session} = SessionStore.create_session(session_id)

    assert_raise ArgumentError, fn ->
      :ets.insert(:snakepit_sessions, {session_id <> "_evil", {0, 0, %{}}})
    end
  end

  test "enforces session quota and respects cleanup" do
    server_name = :session_store_quota_server

    start_supervised!(
      {SessionStore, name: server_name, table_name: :session_store_quota_table, max_sessions: 1}
    )

    assert {:ok, _} = SessionStore.create_session(server_name, "s1", ttl: 0)

    assert {:error, :session_quota_exceeded} =
             SessionStore.create_session(server_name, "s2", [])

    assert_eventually(
      fn ->
        SessionStore.cleanup_expired_sessions(server_name) > 0
      end,
      timeout: 1_200,
      interval: 10
    )

    assert {:ok, _} = SessionStore.create_session(server_name, "s2", ttl: 0)
  end

  test "contains throw and exit failures from update callbacks" do
    session_id = "update_fail_#{System.unique_integer([:positive])}"
    {:ok, _session} = SessionStore.create_session(session_id)

    assert {:error, {:update_failed, {:throw, :thrown_failure}}} =
             SessionStore.update_session(session_id, fn _session ->
               throw(:thrown_failure)
             end)

    assert {:error, {:update_failed, {:exit, :exit_failure}}} =
             SessionStore.update_session(session_id, fn _session ->
               exit(:exit_failure)
             end)

    assert {:ok, _} = SessionStore.get_session(session_id)
  end

  test "store_worker_session respects max session quota on upsert create path" do
    server_name = :session_store_upsert_quota_server

    start_supervised!(
      {SessionStore,
       name: server_name, table_name: :session_store_upsert_quota_table, max_sessions: 1}
    )

    assert :ok = SessionStore.store_worker_session(server_name, "upsert_quota_s1", "worker_1")

    assert {:error, :session_quota_exceeded} =
             SessionStore.store_worker_session(server_name, "upsert_quota_s2", "worker_2")

    assert {:error, :not_found} = SessionStore.get_session(server_name, "upsert_quota_s2")
  end
end
