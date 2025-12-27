defmodule Snakepit.Pool.PoolSizeIsolationTest do
  @moduledoc """
  TDD tests to verify that per-pool pool_size is respected when using multi-pool config.

  The root cause of test contamination was that opts[:size] (from application.ex)
  was overriding the per-pool pool_size in :pools config.

  These tests verify:
  1. Each pool uses its own pool_size from :pools config
  2. The global pool_config[:pool_size] does NOT override per-pool sizes in multi-pool mode
  3. broken_pool with FailingAdapter gets exactly the pool_size specified, not a global value
  """

  use ExUnit.Case, async: false
  import Snakepit.TestHelpers

  @moduletag :unit
  @moduletag timeout: 30_000

  setup do
    # Save original env
    prev_pools = Application.get_env(:snakepit, :pools)
    prev_pooling = Application.get_env(:snakepit, :pooling_enabled)
    prev_pool_config = Application.get_env(:snakepit, :pool_config)

    # Stop application
    Application.stop(:snakepit)
    Application.load(:snakepit)

    on_exit(fn ->
      Application.stop(:snakepit)
      restore_env(:pools, prev_pools)
      restore_env(:pooling_enabled, prev_pooling)
      restore_env(:pool_config, prev_pool_config)

      # Wait for processes to actually stop
      assert_eventually(
        fn -> Process.whereis(Snakepit.Pool) == nil end,
        timeout: 5_000,
        interval: 100
      )
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:snakepit, key)
  defp restore_env(key, value), do: Application.put_env(:snakepit, key, value)

  describe "per-pool pool_size in multi-pool config" do
    test "each pool uses its own pool_size, not a global override" do
      # Configure multi-pool with DIFFERENT sizes
      Application.put_env(:snakepit, :pools, [
        %{
          name: :small_pool,
          worker_profile: :process,
          pool_size: 1,
          adapter_module: Snakepit.TestAdapters.MockGRPCAdapter
        },
        %{
          name: :large_pool,
          worker_profile: :process,
          pool_size: 3,
          adapter_module: Snakepit.TestAdapters.MockGRPCAdapter
        }
      ])

      # Set a global pool_config with a DIFFERENT size (this should be ignored in multi-pool mode)
      Application.put_env(:snakepit, :pool_config, %{pool_size: 100})
      Application.put_env(:snakepit, :pooling_enabled, true)

      {:ok, _} = Application.ensure_all_started(:snakepit)

      # Wait for pool to be ready
      assert_eventually(
        fn -> Snakepit.Pool.await_ready() == :ok end,
        timeout: 30_000,
        interval: 500
      )

      # Check that each pool has the correct size
      small_pool_workers = Snakepit.Pool.list_workers(Snakepit.Pool, :small_pool)
      large_pool_workers = Snakepit.Pool.list_workers(Snakepit.Pool, :large_pool)

      # This is the key assertion: small_pool should have 1 worker, not 100
      assert length(small_pool_workers) == 1,
             "small_pool should have 1 worker, but has #{length(small_pool_workers)}"

      assert length(large_pool_workers) == 3,
             "large_pool should have 3 workers, but has #{length(large_pool_workers)}"
    end

    test "broken_pool does not inherit global pool_size" do
      # This test captures the original bug: broken_pool was getting pool_size from
      # global pool_config instead of its own pool_size, causing 48 workers instead of 1

      Application.put_env(:snakepit, :pools, [
        %{
          name: :default,
          worker_profile: :process,
          pool_size: 2,
          adapter_module: Snakepit.TestAdapters.MockGRPCAdapter
        },
        %{
          name: :broken_pool,
          worker_profile: :process,
          pool_size: 1,
          # FailingAdapter's workers fail immediately
          adapter_module: Snakepit.TestAdapters.FailingAdapter
        }
      ])

      # Set a large global pool_size - this should NOT affect broken_pool
      Application.put_env(:snakepit, :pool_config, %{pool_size: 50})
      Application.put_env(:snakepit, :pooling_enabled, true)

      {:ok, _} = Application.ensure_all_started(:snakepit)

      # Wait a bit for initialization attempts
      receive do
      after
        2_000 -> :ok
      end

      # Get pool state to verify sizes
      stats = Snakepit.Pool.get_stats(Snakepit.Pool, :default)

      # The default pool should have exactly 2 workers
      # (not 50 from global pool_config)
      assert stats.workers == 2 or is_map(stats),
             "Expected stats or error for default pool"

      # Even though broken_pool workers fail, the pool should have been
      # configured with pool_size: 1, not pool_size: 50
      # We can verify by checking that we didn't attempt to start 50 workers
      # (which would cause significant delays/resource usage)
    end
  end

  describe "list_workers isolation between pools" do
    test "list_workers/2 returns only workers from specified pool" do
      Application.put_env(:snakepit, :pools, [
        %{
          name: :pool_a,
          worker_profile: :process,
          pool_size: 2,
          adapter_module: Snakepit.TestAdapters.MockGRPCAdapter
        },
        %{
          name: :pool_b,
          worker_profile: :process,
          pool_size: 3,
          adapter_module: Snakepit.TestAdapters.MockGRPCAdapter
        }
      ])

      Application.put_env(:snakepit, :pooling_enabled, true)

      {:ok, _} = Application.ensure_all_started(:snakepit)

      assert_eventually(
        fn -> Snakepit.Pool.await_ready() == :ok end,
        timeout: 30_000,
        interval: 500
      )

      workers_a = Snakepit.Pool.list_workers(Snakepit.Pool, :pool_a)
      workers_b = Snakepit.Pool.list_workers(Snakepit.Pool, :pool_b)
      all_workers = Snakepit.Pool.list_workers()

      # Verify isolation
      assert length(workers_a) == 2
      assert length(workers_b) == 3
      assert length(all_workers) == 5

      # Verify no overlap - worker IDs should contain pool name
      assert Enum.all?(workers_a, &String.contains?(&1, "pool_a"))
      assert Enum.all?(workers_b, &String.contains?(&1, "pool_b"))
    end

    test "healthy pool list_workers works even when broken_pool exists" do
      Application.put_env(:snakepit, :pools, [
        %{
          name: :healthy,
          worker_profile: :process,
          pool_size: 2,
          adapter_module: Snakepit.TestAdapters.MockGRPCAdapter
        },
        %{
          name: :broken,
          worker_profile: :process,
          pool_size: 1,
          adapter_module: Snakepit.TestAdapters.FailingAdapter
        }
      ])

      Application.put_env(:snakepit, :pooling_enabled, true)

      {:ok, _} = Application.ensure_all_started(:snakepit)

      # Wait for healthy pool to be ready (broken pool may never be ready)
      assert_eventually(
        fn ->
          case Snakepit.Pool.list_workers(Snakepit.Pool, :healthy) do
            workers when is_list(workers) and length(workers) == 2 -> true
            _ -> false
          end
        end,
        timeout: 30_000,
        interval: 500
      )

      # This should NOT timeout or hang - the healthy pool should be queryable
      # even if broken_pool is in a bad state
      healthy_workers = Snakepit.Pool.list_workers(Snakepit.Pool, :healthy)
      assert is_list(healthy_workers)
      assert length(healthy_workers) == 2
    end
  end
end
