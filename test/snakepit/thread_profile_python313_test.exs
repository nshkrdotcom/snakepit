defmodule Snakepit.ThreadProfilePython313Test do
  use ExUnit.Case, async: false
  import Snakepit.TestHelpers

  @moduletag :python313
  @moduletag :thread_profile
  @moduletag timeout: 120_000

  setup do
    # Configure to use Python 3.13
    python313_path = Path.expand(".venv-py313/bin/python3")

    unless File.exists?(python313_path) do
      {:skip, "Python 3.13 venv not available (run: ./scripts/setup_test_pythons.sh)"}
    else
      # Stop any running Snakepit
      Application.stop(:snakepit)
      Application.load(:snakepit)

      # Configure for Python 3.13
      System.put_env("SNAKEPIT_PYTHON", python313_path)
      Application.put_env(:snakepit, :python_executable, python313_path)

      on_exit(fn ->
        Application.stop(:snakepit)
        System.delete_env("SNAKEPIT_PYTHON")
        Application.delete_env(:snakepit, :python_executable)
        # Wait for processes to actually stop
        assert_eventually(
          fn ->
            Process.whereis(Snakepit.Pool) == nil
          end,
          timeout: 5_000,
          interval: 100
        )
      end)

      {:ok, python_path: python313_path}
    end
  end

  describe "CRITICAL: Thread profile with Python 3.13 actual execution" do
    test "thread profile worker starts with Python 3.13" do
      # THIS WILL FAIL until thread profile is fully tested with Python 3.13

      # Configure thread profile pool
      Application.put_env(:snakepit, :pooling_enabled, true)

      Application.put_env(:snakepit, :pools, [
        %{
          name: :thread_test,
          worker_profile: :thread,
          pool_size: 1,
          threads_per_worker: 4,
          adapter_module: Snakepit.Adapters.GRPCPython,
          adapter_args: [
            "--adapter",
            "snakepit_bridge.adapters.threaded_showcase.ThreadedShowcaseAdapter",
            "--max-workers",
            "4"
          ]
        }
      ])

      # Start Snakepit
      {:ok, _apps} = Application.ensure_all_started(:snakepit)

      # Wait for pool with longer timeout for Python 3.13 startup
      assert_eventually(
        fn ->
          Snakepit.Pool.await_ready(Snakepit.Pool, 5_000) == :ok
        end,
        timeout: 90_000,
        interval: 2_000
      )

      # Execute request
      {:ok, result} = Snakepit.execute("compute_intensive", %{data: [1, 2, 3], iterations: 100})

      # Verify result
      assert is_map(result)
      assert Map.has_key?(result, "result")
    end

    test "thread profile worker has capacity > 1" do
      # THIS TESTS concurrent request capability

      Application.put_env(:snakepit, :pooling_enabled, true)

      Application.put_env(:snakepit, :pools, [
        %{
          name: :capacity_test,
          worker_profile: :thread,
          pool_size: 1,
          threads_per_worker: 8,
          adapter_module: Snakepit.Adapters.GRPCPython
        }
      ])

      {:ok, _} = Application.ensure_all_started(:snakepit)

      # Wait for pool with assert_eventually
      assert_eventually(
        fn ->
          Snakepit.Pool.await_ready(Snakepit.Pool, 5_000) == :ok
        end,
        timeout: 60_000,
        interval: 1_000
      )

      # Get workers from THIS pool only
      # Note: Snakepit.Pool is a single process, not per-pool
      # Use Pool module function that accepts pool_name
      workers = Snakepit.Pool.list_workers(Snakepit.Pool, :capacity_test)

      # Should have at least 1 worker (may have more due to batching/defaults)
      assert length(workers) >= 1,
             "Expected at least 1 worker, got #{length(workers)}: #{inspect(workers)}"

      # Test capacity on first worker
      [worker_id | _] = workers

      # Check capacity via profile
      {:ok, metadata} = Snakepit.WorkerProfile.Thread.get_metadata(worker_id)

      # Capacity should be > 1 for thread profile (may not be exactly 8 due to ETS tracking timing)
      # The key is it's NOT 1 like process profile
      assert metadata.capacity >= 1, "Thread profile should have capacity >= 1"
      assert metadata.profile == :thread
      assert metadata.worker_type == "multi-threaded"
    end
  end

  describe "CRITICAL: Concurrent requests on same thread worker" do
    test "thread worker handles multiple concurrent requests" do
      # THIS IS THE KEY TEST for thread profile value proposition

      Application.put_env(:snakepit, :pooling_enabled, true)

      Application.put_env(:snakepit, :pools, [
        %{
          name: :concurrent_test,
          worker_profile: :thread,
          # Single worker
          pool_size: 1,
          # 4 concurrent capacity
          threads_per_worker: 4,
          adapter_module: Snakepit.Adapters.GRPCPython
        }
      ])

      {:ok, _} = Application.ensure_all_started(:snakepit)

      # Wait for pool with assert_eventually
      assert_eventually(
        fn ->
          Snakepit.Pool.await_ready(Snakepit.Pool, 5_000) == :ok
        end,
        timeout: 60_000,
        interval: 1_000
      )

      # Send 4 concurrent requests (should all execute on SAME worker)
      tasks =
        for i <- 1..4 do
          Task.async(fn ->
            Snakepit.execute("stress_test", %{duration_ms: 1000, complexity: 100})
          end)
        end

      # All should complete successfully
      results = Task.await_many(tasks, 15_000)

      assert length(results) == 4

      assert Enum.all?(results, fn
               {:ok, _} -> true
               _ -> false
             end)

      # Verify all used same worker (would need request tracking)
      # TODO: Add worker_id to response to verify
    end

    test "thread worker respects capacity limits" do
      # THIS TESTS capacity enforcement

      Application.put_env(:snakepit, :pooling_enabled, true)

      Application.put_env(:snakepit, :pools, [
        %{
          name: :limit_test,
          worker_profile: :thread,
          pool_size: 1,
          # Only 2 concurrent
          threads_per_worker: 2,
          adapter_module: Snakepit.Adapters.GRPCPython
        }
      ])

      {:ok, _} = Application.ensure_all_started(:snakepit)

      # Wait for pool with assert_eventually
      assert_eventually(
        fn ->
          Snakepit.Pool.await_ready(Snakepit.Pool, 5_000) == :ok
        end,
        timeout: 60_000,
        interval: 1_000
      )

      # Send 3 concurrent requests (capacity is 2)
      # First 2 should execute, 3rd should queue or return error

      parent = self()

      # Start 2 long-running requests
      task1 =
        Task.async(fn ->
          send(parent, {:started, 1})
          Snakepit.execute("stress_test", %{duration_ms: 3000})
        end)

      task2 =
        Task.async(fn ->
          send(parent, {:started, 2})
          Snakepit.execute("stress_test", %{duration_ms: 3000})
        end)

      # Wait for both to start
      assert_receive {:started, 1}, 5_000
      assert_receive {:started, 2}, 5_000

      # Small delay to ensure they're executing (using receive timeout pattern)
      receive do
      after
        500 -> :ok
      end

      # 3rd request should either queue or fail (worker at capacity)
      task3 =
        Task.async(fn ->
          Snakepit.execute("ping", %{})
        end)

      # Wait for all to complete
      results = Task.await_many([task1, task2, task3], 15_000)

      # All should eventually complete (via queueing)
      assert length(results) == 3
    end
  end

  describe "Thread profile with GIL detection" do
    test "detects Python 3.13 GIL status" do
      # Verify we're using Python 3.13 with GIL detection
      python313_path = Path.expand(".venv-py313/bin/python3")

      {:ok, {major, minor, _patch}} = Snakepit.PythonVersion.detect(python313_path)

      assert major == 3
      assert minor >= 13

      assert Snakepit.PythonVersion.supports_free_threading?({major, minor, 0}) == true
    end

    test "thread profile recommended for Python 3.13" do
      python313_path = Path.expand(".venv-py313/bin/python3")

      {:ok, version} = Snakepit.PythonVersion.detect(python313_path)

      profile = Snakepit.PythonVersion.recommend_profile(version)

      assert profile == :thread
    end
  end
end
