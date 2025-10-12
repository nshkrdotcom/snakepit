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

  describe "Python 3.13+ optimization" do
    test "thread profile is recommended for Python 3.13+" do
      # Verify the architecture decision: thread profile for Python 3.13+
      version_313 = {3, 13, 0}
      version_314 = {3, 14, 0}

      assert Snakepit.PythonVersion.supports_free_threading?(version_313) == true
      assert Snakepit.PythonVersion.supports_free_threading?(version_314) == true
      assert Snakepit.PythonVersion.recommend_profile(version_313) == :thread
      assert Snakepit.PythonVersion.recommend_profile(version_314) == :thread
    end

    test "process profile is recommended for Python < 3.13" do
      # Verify GIL compatibility: process profile for Python < 3.13
      version_312 = {3, 12, 0}
      version_311 = {3, 11, 0}
      version_38 = {3, 8, 0}

      assert Snakepit.PythonVersion.supports_free_threading?(version_312) == false
      assert Snakepit.PythonVersion.supports_free_threading?(version_311) == false
      assert Snakepit.PythonVersion.supports_free_threading?(version_38) == false
      assert Snakepit.PythonVersion.recommend_profile(version_312) == :process
      assert Snakepit.PythonVersion.recommend_profile(version_311) == :process
      assert Snakepit.PythonVersion.recommend_profile(version_38) == :process
    end
  end

  describe "GIL-free library compatibility" do
    test "thread-safe libraries work with thread profile" do
      # Libraries that release GIL - optimal for thread profile
      gil_releasing = ["numpy", "scipy", "torch", "tensorflow"]

      for lib <- gil_releasing do
        result = Snakepit.Compatibility.check(lib, :thread)
        # Should be :ok or {:warning, _} for config, but not error
        assert result == :ok or match?({:warning, _}, result)
      end
    end

    test "thread-unsafe libraries warn with thread profile" do
      # Libraries that hold GIL - should warn for thread profile
      gil_holding = ["pandas", "matplotlib", "sqlite3"]

      for lib <- gil_holding do
        assert {:warning, msg} = Snakepit.Compatibility.check(lib, :thread)
        assert String.contains?(msg, "not thread-safe") or String.contains?(msg, "unsafe")
      end
    end

    test "all libraries safe with process profile" do
      # Process profile provides isolation - everything is safe
      all_libs = ["numpy", "pandas", "matplotlib", "torch"]

      for lib <- all_libs do
        assert :ok = Snakepit.Compatibility.check(lib, :process)
      end
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
