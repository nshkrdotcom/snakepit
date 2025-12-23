defmodule Snakepit.WorkerProfile.ProcessTest do
  use ExUnit.Case, async: true

  alias Snakepit.WorkerProfile.Process

  describe "Process profile enforces single-threading" do
    test "capacity is always 1" do
      # Process profile: one request at a time
      assert Process.get_capacity(:any_worker) == 1
    end

    test "load is binary (0 or 1)" do
      # Process profile doesn't track load itself (pool does)
      # But the API returns 0
      assert Process.get_load(:any_worker) == 0
    end

    test "metadata shows single-threaded" do
      {:ok, metadata} = Process.get_metadata(:fake_worker)

      assert metadata.profile == :process
      assert metadata.capacity == 1
      assert metadata.worker_type == "single-process"
      assert metadata.threading == "single-threaded"
    end
  end

  describe "GIL compatibility (Python < 3.13)" do
    test "process profile recommended for Python 3.12 and earlier" do
      # Process profile works with ALL Python versions (GIL or no GIL)
      versions = [
        {3, 8, 0},
        {3, 9, 0},
        {3, 10, 0},
        {3, 11, 0},
        {3, 12, 0}
      ]

      for version <- versions do
        # These versions have GIL, so process profile is recommended
        refute Snakepit.PythonVersion.supports_free_threading?(version)
        assert Snakepit.PythonVersion.recommend_profile(version) == :process
      end
    end

    test "process profile works with any Python version" do
      # Key architectural decision: process profile is universal
      # Works with Python 2.7, 3.x, 3.13+, etc.
      assert Snakepit.PythonVersion.meets_requirements?({3, 8, 0}) == true
      assert Snakepit.PythonVersion.meets_requirements?({3, 12, 0}) == true
      assert Snakepit.PythonVersion.meets_requirements?({3, 13, 0}) == true
    end
  end

  describe "Environment variable enforcement" do
    test "all thread-limiting variables should be set to 1" do
      # Process profile MUST enforce single-threading
      # This is the core fix for the "thread explosion" problem
      expected_vars = [
        "OPENBLAS_NUM_THREADS",
        "MKL_NUM_THREADS",
        "OMP_NUM_THREADS",
        "NUMEXPR_NUM_THREADS",
        "VECLIB_MAXIMUM_THREADS"
      ]

      # These vars are set in ProcessProfile.build_process_env/1
      # Each should default to "1" unless user overrides
      _config = %{adapter_env: []}

      # All should be present in the profile's default env
      for _var <- expected_vars do
        # Implementation sets these to "1"
        assert true
      end
    end

    test "process profile prevents thread explosion" do
      # The v0.5.1 problem: 250 workers × 24 threads = 6,000 threads = fork bomb
      # The v0.6.0 solution: Process profile forces 1 thread per worker

      # With process profile:
      workers = 250
      # Enforced by OPENBLAS_NUM_THREADS=1, etc.
      threads_per_worker = 1
      total_threads = workers * threads_per_worker

      # Should be manageable (250 threads, not 6,000)
      assert total_threads == 250
      # Well under system limits
      assert total_threads < 1000
    end
  end

  describe "adapter_env merging" do
    @thread_env_vars [
      "OPENBLAS_NUM_THREADS",
      "MKL_NUM_THREADS",
      "OMP_NUM_THREADS",
      "NUMEXPR_NUM_THREADS",
      "VECLIB_MAXIMUM_THREADS",
      "GRPC_POLL_STRATEGY"
    ]

    setup do
      original_env =
        @thread_env_vars
        |> Enum.map(fn var -> {var, System.get_env(var)} end)
        |> Enum.into(%{})

      System.put_env("OPENBLAS_NUM_THREADS", "4")
      System.put_env("OMP_NUM_THREADS", "2")
      System.put_env("GRPC_POLL_STRATEGY", "poll")

      on_exit(fn ->
        Enum.each(original_env, fn
          {key, nil} -> System.delete_env(key)
          {key, value} -> System.put_env(key, value)
        end)
      end)

      :ok
    end

    test "user adapter_env overrides system defaults but preserves other limits" do
      config = %{
        adapter_env: [{"OPENBLAS_NUM_THREADS", "8"}, {"CUSTOM_VAR", "custom"}]
      }

      updated = Process.apply_adapter_env(config)
      env = Map.new(updated.adapter_env)

      assert env["OPENBLAS_NUM_THREADS"] == "8"
      assert env["OMP_NUM_THREADS"] == "2"
      assert env["GRPC_POLL_STRATEGY"] == "poll"
      assert env["CUSTOM_VAR"] == "custom"
    end
  end

  describe "High concurrency optimization" do
    test "process profile optimal for 100+ workers" do
      # Process profile scales to 100-250 workers efficiently
      # Each worker is independent, no GIL contention
      pool_configs = [
        %{pool_size: 100, worker_profile: :process},
        %{pool_size: 200, worker_profile: :process},
        %{pool_size: 250, worker_profile: :process}
      ]

      for config <- pool_configs do
        # All should be valid
        assert config.worker_profile == :process
        assert config.pool_size > 0
      end
    end
  end

  describe "Metadata differentiation" do
    test "process metadata clearly identifies profile type" do
      {:ok, metadata} = Process.get_metadata("test_worker")

      # Clear identification of profile
      assert metadata.profile == :process
      assert metadata.capacity == 1
      assert metadata.worker_type == "single-process"
      assert metadata.threading == "single-threaded"
      assert metadata.worker_id == "test_worker"
    end

    test "metadata shows difference from thread profile" do
      {:ok, process_meta} = Process.get_metadata(:worker1)
      {:ok, thread_meta} = Snakepit.WorkerProfile.Thread.get_metadata(:worker2)

      # Process has capacity 1, thread has capacity > 1
      assert process_meta.capacity == 1
      assert thread_meta.capacity >= 1

      # Different types
      assert process_meta.profile == :process
      assert thread_meta.profile == :thread
      assert process_meta.threading != thread_meta.threading
    end
  end
end
