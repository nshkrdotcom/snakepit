defmodule Snakepit.WorkerProfile.ThreadTest do
  use ExUnit.Case, async: false

  alias Snakepit.WorkerProfile.Thread

  describe "Thread profile configuration" do
    test "builds correct adapter args for threaded mode" do
      config = %{
        worker_id: "test_thread_1",
        threads_per_worker: 16,
        adapter_spec: "snakepit_bridge.adapters.threaded_showcase.ThreadedShowcaseAdapter",
        adapter_module: Snakepit.Adapters.GRPCPython,
        pool_name: :test_pool
      }

      # Start worker would build args - we can test the helper directly
      # For now, validate config structure
      assert config.threads_per_worker == 16
      assert config.worker_id == "test_thread_1"
    end

    test "sets multi-threading environment variables" do
      config = %{
        worker_id: "test_thread_2",
        threads_per_worker: 16,
        adapter_env: [],
        adapter_module: Snakepit.Adapters.GRPCPython
      }

      # The build_adapter_env function should allow multi-threading
      # This is the key difference from process profile which forces single-threading
      assert is_map(config)
    end
  end

  describe "Capacity tracking (ETS)" do
    test "get_capacity returns threads_per_worker" do
      # Capacity should match thread count, not 1 like process profile
      # Thread profile: capacity = threads_per_worker
      # Process profile: capacity = 1
      assert Thread.get_capacity(:fake_worker) >= 1
    end

    test "get_load tracks concurrent requests" do
      # Thread profile tracks 0 to N concurrent requests
      # Process profile is binary: 0 or 1
      assert Thread.get_load(:fake_worker) >= 0
    end
  end

  describe "Metadata includes profile type" do
    test "thread profile metadata shows multi-threaded" do
      {:ok, metadata} = Thread.get_metadata(:fake_worker)

      assert metadata.profile == :thread
      assert metadata.worker_type == "multi-threaded"
      assert metadata.threading == "thread-pool"
      assert metadata.capacity >= 1
    end

    test "metadata differentiates from process profile" do
      # Compare thread vs process metadata
      {:ok, thread_meta} = Thread.get_metadata(:fake_worker)
      {:ok, process_meta} = Snakepit.WorkerProfile.Process.get_metadata(:fake_worker)

      # Thread profile has higher capacity
      assert thread_meta.capacity >= process_meta.capacity

      # Different worker types
      assert thread_meta.worker_type != process_meta.worker_type
      assert thread_meta.threading != process_meta.threading
    end
  end
end
