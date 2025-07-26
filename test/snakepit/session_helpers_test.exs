defmodule Snakepit.SessionHelpersTest do
  use ExUnit.Case
  alias Snakepit.SessionHelpers

  describe "session ID generation" do
    test "generates unique session IDs" do
      id1 = SessionHelpers.generate_session_id()
      id2 = SessionHelpers.generate_session_id()
      
      assert id1 != id2
      assert is_binary(id1)
      assert is_binary(id2)
      assert String.length(id1) > 0
      assert String.length(id2) > 0
    end

    test "generates session IDs with prefix" do
      id = SessionHelpers.generate_session_id("test")
      
      assert String.starts_with?(id, "test_")
      assert String.length(id) > String.length("test_")
    end
  end

  describe "session validation" do
    test "validates valid session IDs" do
      valid_ids = [
        "session_123",
        "test_abc_def",
        "user_12345",
        SessionHelpers.generate_session_id()
      ]
      
      for id <- valid_ids do
        assert SessionHelpers.valid_session_id?(id) == true
      end
    end

    test "rejects invalid session IDs" do
      invalid_ids = [
        "",
        nil,
        123,
        :atom,
        %{},
        []
      ]
      
      for id <- invalid_ids do
        assert SessionHelpers.valid_session_id?(id) == false
      end
    end
  end

  describe "session metadata" do
    test "creates session metadata" do
      metadata = SessionHelpers.create_metadata("test_session", %{user_id: 123})
      
      assert metadata.session_id == "test_session"
      assert metadata.user_id == 123
      assert metadata.created_at != nil
      assert is_integer(metadata.created_at)
    end

    test "creates metadata with defaults" do
      metadata = SessionHelpers.create_metadata("test_session")
      
      assert metadata.session_id == "test_session"
      assert metadata.created_at != nil
      assert map_size(metadata) == 2
    end

    test "merges additional metadata" do
      metadata = SessionHelpers.create_metadata("test_session", %{
        user_id: 123,
        ip_address: "127.0.0.1",
        custom: "value"
      })
      
      assert metadata.session_id == "test_session"
      assert metadata.user_id == 123
      assert metadata.ip_address == "127.0.0.1"
      assert metadata.custom == "value"
      assert metadata.created_at != nil
    end
  end

  describe "session routing" do
    test "calculates consistent worker assignment" do
      session_id = "test_session"
      worker_count = 5
      
      # Same session ID should always route to same worker
      assignment1 = SessionHelpers.calculate_worker_assignment(session_id, worker_count)
      assignment2 = SessionHelpers.calculate_worker_assignment(session_id, worker_count)
      
      assert assignment1 == assignment2
      assert assignment1 >= 0
      assert assignment1 < worker_count
    end

    test "distributes sessions across workers" do
      worker_count = 10
      session_count = 100
      
      # Generate many sessions and check distribution
      assignments = for i <- 1..session_count do
        session_id = "session_#{i}"
        SessionHelpers.calculate_worker_assignment(session_id, worker_count)
      end
      
      # Count assignments per worker
      distribution = Enum.frequencies(assignments)
      
      # All workers should have some assignments
      assert map_size(distribution) == worker_count
      
      # Distribution should be reasonably balanced (not perfect due to hashing)
      values = Map.values(distribution)
      min_assignments = Enum.min(values)
      max_assignments = Enum.max(values)
      
      # Allow for some variation but not extreme imbalance
      assert max_assignments / min_assignments < 3.0
    end
  end

  describe "session cleanup" do
    test "identifies expired sessions" do
      now = System.system_time(:second)
      ttl = 3600 # 1 hour
      
      sessions = [
        %{session_id: "old_1", last_activity: now - 7200}, # 2 hours ago
        %{session_id: "old_2", last_activity: now - 3700}, # Just over 1 hour
        %{session_id: "recent_1", last_activity: now - 1800}, # 30 minutes ago
        %{session_id: "recent_2", last_activity: now - 60} # 1 minute ago
      ]
      
      expired = SessionHelpers.find_expired_sessions(sessions, ttl)
      
      assert length(expired) == 2
      assert "old_1" in Enum.map(expired, & &1.session_id)
      assert "old_2" in Enum.map(expired, & &1.session_id)
    end

    test "handles empty session list" do
      assert SessionHelpers.find_expired_sessions([], 3600) == []
    end
  end

  describe "session options parsing" do
    test "extracts session options from keyword list" do
      opts = [
        session_id: "test_123",
        timeout: 5000,
        other: "value"
      ]
      
      {session_opts, remaining_opts} = SessionHelpers.extract_session_opts(opts)
      
      assert session_opts.session_id == "test_123"
      assert session_opts.timeout == 5000
      assert remaining_opts == [other: "value"]
    end

    test "provides defaults for missing options" do
      opts = [other: "value"]
      
      {session_opts, remaining_opts} = SessionHelpers.extract_session_opts(opts)
      
      assert session_opts.session_id != nil
      assert session_opts.timeout == 5000 # default
      assert remaining_opts == [other: "value"]
    end

    test "generates session ID if not provided" do
      {session_opts1, _} = SessionHelpers.extract_session_opts([])
      {session_opts2, _} = SessionHelpers.extract_session_opts([])
      
      assert session_opts1.session_id != session_opts2.session_id
    end
  end
end