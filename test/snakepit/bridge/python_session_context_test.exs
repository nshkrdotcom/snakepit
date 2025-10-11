defmodule Snakepit.Bridge.PythonSessionContextTest do
  @moduledoc """
  Tests for Python SessionContext integration with Elixir SessionStore.

  These tests verify the minimal Python SessionContext can properly
  interact with Elixir's session management system.
  """

  use ExUnit.Case, async: false
  alias Snakepit.Bridge.{SessionStore, Session}

  setup do
    # Ensure SessionStore is running
    # If it's not running (crashed or not started), start it for this test
    case Process.whereis(SessionStore) do
      nil ->
        # Start SessionStore if not running
        {:ok, _} = start_supervised({SessionStore, name: SessionStore})

      pid when is_pid(pid) ->
        # SessionStore is already running from application
        :ok
    end

    session_id = "python_test_#{:erlang.unique_integer([:positive])}"
    {:ok, session} = SessionStore.create_session(session_id)

    on_exit(fn ->
      try do
        SessionStore.delete_session(session_id)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, session: session, session_id: session_id}
  end

  describe "session lifecycle with Python" do
    test "Python SessionContext can use session_id from Elixir SessionStore", %{
      session_id: session_id
    } do
      # Verify session exists in SessionStore
      assert {:ok, session} = SessionStore.get_session(session_id)
      assert session.id == session_id

      # In real usage, Python would:
      # 1. Receive session_id in InitializeSession RPC
      # 2. Create SessionContext(stub, session_id)
      # 3. Use session_id for tracking

      # Simulate Python accessing the session
      assert SessionStore.session_exists?(session_id)

      # Verify session can be updated (Python would do this via SessionStore)
      assert {:ok, _updated} =
               SessionStore.update_session(session_id, fn session ->
                 Session.put_metadata(session, "python_used", true)
               end)
    end

    test "session expires after TTL", %{session_id: session_id} do
      # Create session with short TTL
      short_ttl_session_id = "short_ttl_#{:erlang.unique_integer([:positive])}"
      {:ok, _session} = SessionStore.create_session(short_ttl_session_id, ttl: 1)

      # Session exists initially
      assert SessionStore.session_exists?(short_ttl_session_id)

      # Wait for expiration (TTL + buffer for monotonic time precision)
      :timer.sleep(2000)

      # Trigger cleanup
      SessionStore.cleanup_expired_sessions()

      # Session should be gone
      refute SessionStore.session_exists?(short_ttl_session_id)
    end

    test "Python SessionContext cleanup is best-effort", %{session_id: session_id} do
      # Session exists
      assert SessionStore.session_exists?(session_id)

      # Python cleanup calls CleanupSession RPC
      # This is a best-effort operation - SessionStore handles actual cleanup via TTL

      # Delete session (simulating cleanup)
      :ok = SessionStore.delete_session(session_id)

      # Session should be gone
      refute SessionStore.session_exists?(session_id)

      # Multiple cleanups should not error (idempotent)
      :ok = SessionStore.delete_session(session_id)
    end
  end

  describe "program storage for stateful execution" do
    test "Python can store and retrieve programs via SessionStore", %{session_id: session_id} do
      program_id = "dspy_cot_v1"

      program_data = %{
        "type" => "ChainOfThought",
        "signature" => "question -> answer",
        "compiled" => true,
        "parameters" => %{
          "temperature" => 0.7,
          "max_tokens" => 150
        }
      }

      # Store program (Python would do this via RPC)
      assert :ok = SessionStore.store_program(session_id, program_id, program_data)

      # Retrieve program
      assert {:ok, retrieved} = SessionStore.get_program(session_id, program_id)
      assert retrieved["type"] == "ChainOfThought"
      assert retrieved["compiled"] == true

      # Update program
      updated_data = Map.put(program_data, "version", 2)
      assert :ok = SessionStore.update_program(session_id, program_id, updated_data)

      # Verify update
      assert {:ok, retrieved} = SessionStore.get_program(session_id, program_id)
      assert retrieved["version"] == 2
    end

    test "programs are cleaned up with session", %{session_id: session_id} do
      # Store program
      :ok = SessionStore.store_program(session_id, "prog_1", %{"data" => "test"})

      # Program exists
      assert {:ok, _} = SessionStore.get_program(session_id, "prog_1")

      # Delete session
      :ok = SessionStore.delete_session(session_id)

      # Program should be gone with session
      assert {:error, :not_found} = SessionStore.get_program(session_id, "prog_1")
    end
  end

  describe "worker affinity" do
    test "SessionStore tracks worker affinity", %{session_id: session_id} do
      worker_id = "pool_worker_1_123"

      # Store worker-session affinity
      :ok = SessionStore.store_worker_session(session_id, worker_id)

      # Verify affinity was stored
      {:ok, session} = SessionStore.get_session(session_id)
      assert session.last_worker_id == worker_id

      # Update with different worker
      new_worker_id = "pool_worker_2_456"
      :ok = SessionStore.store_worker_session(session_id, new_worker_id)

      {:ok, session} = SessionStore.get_session(session_id)
      assert session.last_worker_id == new_worker_id
    end

    test "worker affinity enables routing optimization", %{session_id: session_id} do
      # First request - assign to worker
      :ok = SessionStore.store_worker_session(session_id, "worker_1")

      # Subsequent requests can check affinity
      {:ok, session} = SessionStore.get_session(session_id)
      preferred_worker = session.last_worker_id

      assert preferred_worker == "worker_1"

      # Router can use this to send requests to same worker
      # (for memory locality, warm caches, etc.)
    end
  end

  describe "global programs for anonymous operations" do
    test "global programs accessible across workers" do
      program_id = "global_qa_chain"

      program_data = %{
        "type" => "QAChain",
        "shared" => true
      }

      # Store global program
      assert :ok = SessionStore.store_global_program(program_id, program_data)

      # Any worker can retrieve it
      assert {:ok, retrieved} = SessionStore.get_global_program(program_id)
      assert retrieved["type"] == "QAChain"
      assert retrieved["shared"] == true

      # Cleanup
      :ok = SessionStore.delete_global_program(program_id)
      assert {:error, :not_found} = SessionStore.get_global_program(program_id)
    end
  end

  describe "session metadata" do
    test "Python can store custom metadata", %{session_id: session_id} do
      # Python adapter can store arbitrary metadata
      {:ok, _} =
        SessionStore.update_session(session_id, fn session ->
          session
          |> Session.put_metadata("python_version", "3.12")
          |> Session.put_metadata("adapter", "showcase")
          |> Session.put_metadata("user_id", "test_user_123")
        end)

      # Retrieve and verify
      {:ok, session} = SessionStore.get_session(session_id)
      assert Session.get_metadata(session, "python_version") == "3.12"
      assert Session.get_metadata(session, "adapter") == "showcase"
      assert Session.get_metadata(session, "user_id") == "test_user_123"
    end
  end

  describe "session statistics" do
    test "SessionStore tracks session stats", %{session_id: session_id} do
      # Get initial stats
      stats = SessionStore.get_stats()

      assert stats.current_sessions >= 1
      assert stats.sessions_created >= 1
      assert is_integer(stats.memory_usage_bytes)

      # Add program
      :ok = SessionStore.store_program(session_id, "prog_1", %{})

      # Get session to verify program was stored
      {:ok, session} = SessionStore.get_session(session_id)

      # Verify program exists
      assert {:ok, _} = Session.get_program(session, "prog_1")

      # Session stats show program count
      session_stats = Session.get_stats(session)
      # At least the one we added
      assert session_stats.total_items >= 1
      assert session_stats.age >= 0
      assert session_stats.time_since_access >= 0
    end
  end
end
