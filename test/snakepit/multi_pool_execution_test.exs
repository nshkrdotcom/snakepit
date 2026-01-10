defmodule Snakepit.MultiPoolExecutionTest do
  @moduledoc """
  Tests for multi-pool execution and pool isolation.

  These tests verify:
  1. Multiple pools can be configured and run simultaneously
  2. Broken pools don't affect healthy pools
  3. Execution can be routed to specific pools via pool_name option
  4. Each pool has independent worker sets
  """
  use ExUnit.Case, async: false
  import Snakepit.TestHelpers

  @moduletag :multi_pool
  @moduletag :python_integration
  @moduletag timeout: 120_000

  setup do
    prev_pools = Application.get_env(:snakepit, :pools)
    prev_pooling = Application.get_env(:snakepit, :pooling_enabled)
    prev_pool_config = Application.get_env(:snakepit, :pool_config)

    # Stop any running Snakepit
    Application.stop(:snakepit)
    Application.load(:snakepit)

    on_exit(fn ->
      Application.stop(:snakepit)
      restore_env(:pools, prev_pools)
      restore_env(:pooling_enabled, prev_pooling)
      restore_env(:pool_config, prev_pool_config)
      # Wait for processes to actually stop
      assert_eventually(
        fn ->
          Process.whereis(Snakepit.Pool) == nil
        end,
        timeout: 5_000,
        interval: 100
      )

      {:ok, _} = Application.ensure_all_started(:snakepit)

      if prev_pooling do
        assert_eventually(
          fn ->
            Snakepit.Pool.await_ready(Snakepit.Pool, 5_000) == :ok
          end,
          timeout: 30_000,
          interval: 1_000
        )
      end
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:snakepit, key)
  defp restore_env(key, value), do: Application.put_env(:snakepit, key, value)

  describe "pool failure isolation" do
    test "broken pool does not stop healthy pools from serving traffic" do
      Application.put_env(:snakepit, :pooling_enabled, true)

      Application.put_env(:snakepit, :pools, [
        %{
          name: :default,
          worker_profile: :process,
          pool_size: 1,
          adapter_module: Snakepit.TestAdapters.MockGRPCAdapter
        },
        %{
          name: :broken_pool,
          worker_profile: :process,
          pool_size: 1,
          adapter_module: Snakepit.TestAdapters.FailingAdapter
        }
      ])

      {:ok, _} = Application.ensure_all_started(:snakepit)

      # Wait for at least one worker to be available (from the healthy pool)
      assert_eventually(
        fn ->
          Snakepit.Pool.list_workers()
          |> Enum.count() >= 1
        end,
        timeout: 10_000,
        interval: 200
      )

      # Execute on the healthy default pool should succeed
      assert {:ok, result} = Snakepit.execute("ping", %{}, pool_name: :default)
      assert is_map(result)

      # Execute on the broken pool should fail with :pool_not_initialized
      # (since all workers failed to start)
      assert {:error, :pool_not_initialized} =
               Snakepit.execute("ping", %{}, pool_name: :broken_pool)
    end

    test "list_workers for healthy pool works even when broken pool exists" do
      Application.put_env(:snakepit, :pooling_enabled, true)

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

      {:ok, _} = Application.ensure_all_started(:snakepit)

      # Wait for healthy pool workers
      assert_eventually(
        fn ->
          case Snakepit.Pool.list_workers(Snakepit.Pool, :healthy) do
            [_ | _] = _workers -> true
            _ -> false
          end
        end,
        timeout: 15_000,
        interval: 300
      )

      # Query workers from healthy pool - should not timeout or hang
      healthy_workers = Snakepit.Pool.list_workers(Snakepit.Pool, :healthy)
      assert is_list(healthy_workers)
      assert length(healthy_workers) == 2

      # Query workers from broken pool - should return empty or error
      broken_result = Snakepit.Pool.list_workers(Snakepit.Pool, :broken)
      assert is_list(broken_result) and Enum.empty?(broken_result)
    end
  end

  describe "multi-pool configuration and execution" do
    test "starts two pools with different names and executes on both" do
      # Configure TWO pools with real Python adapter
      Application.put_env(:snakepit, :pooling_enabled, true)

      Application.put_env(:snakepit, :pools, [
        %{
          name: :pool_a,
          worker_profile: :process,
          pool_size: 2,
          adapter_module: Snakepit.Adapters.GRPCPython
        },
        %{
          name: :pool_b,
          worker_profile: :process,
          pool_size: 2,
          adapter_module: Snakepit.Adapters.GRPCPython
        }
      ])

      # Start Snakepit
      {:ok, _apps} = Application.ensure_all_started(:snakepit)

      # Wait for pool to be ready
      assert_eventually(
        fn ->
          Snakepit.Pool.await_ready(Snakepit.Pool, 5_000) == :ok
        end,
        timeout: 60_000,
        interval: 1_000
      )

      # Execute on pool_a using pool_name option
      {:ok, result_a} = Snakepit.execute("ping", %{message: "to_pool_a"}, pool_name: :pool_a)
      assert is_map(result_a)

      # Execute on pool_b using pool_name option
      {:ok, result_b} = Snakepit.execute("ping", %{message: "to_pool_b"}, pool_name: :pool_b)
      assert is_map(result_b)
    end

    test "pools have independent worker sets" do
      Application.put_env(:snakepit, :pooling_enabled, true)

      Application.put_env(:snakepit, :pools, [
        %{
          name: :pool_a,
          worker_profile: :process,
          pool_size: 2,
          adapter_module: Snakepit.Adapters.GRPCPython
        },
        %{
          name: :pool_b,
          worker_profile: :process,
          pool_size: 3,
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

      # Query workers from each pool
      workers_a = Snakepit.Pool.list_workers(Snakepit.Pool, :pool_a)
      workers_b = Snakepit.Pool.list_workers(Snakepit.Pool, :pool_b)
      all_workers = Snakepit.Pool.list_workers()

      # Verify each pool has correct count
      assert length(workers_a) == 2, "pool_a should have 2 workers"
      assert length(workers_b) == 3, "pool_b should have 3 workers"
      assert length(all_workers) == 5, "total should be 5 workers"

      # Verify worker IDs are unique between pools
      assert Enum.all?(workers_a, &String.contains?(&1, "pool_a")),
             "pool_a workers should have pool_a in their ID"

      assert Enum.all?(workers_b, &String.contains?(&1, "pool_b")),
             "pool_b workers should have pool_b in their ID"
    end
  end

  describe "pool routing by name" do
    test "Snakepit.execute routes to named pool via pool_name option" do
      Application.put_env(:snakepit, :pooling_enabled, true)

      Application.put_env(:snakepit, :pools, [
        %{
          name: :named_pool,
          worker_profile: :process,
          pool_size: 2,
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

      # Execute with pool_name option
      {:ok, result} = Snakepit.execute("ping", %{}, pool_name: :named_pool)
      assert is_map(result)
    end

    test "can execute on :pool_a and :pool_b independently" do
      Application.put_env(:snakepit, :pooling_enabled, true)

      Application.put_env(:snakepit, :pools, [
        %{
          name: :pool_a,
          worker_profile: :process,
          pool_size: 2,
          adapter_module: Snakepit.Adapters.GRPCPython
        },
        %{
          name: :pool_b,
          worker_profile: :process,
          pool_size: 2,
          adapter_module: Snakepit.Adapters.GRPCPython
        }
      ])

      {:ok, _} = Application.ensure_all_started(:snakepit)

      assert_eventually(
        fn ->
          Snakepit.Pool.await_ready(Snakepit.Pool, 5_000) == :ok
        end,
        timeout: 60_000,
        interval: 1_000
      )

      # Execute multiple requests on pool_a (ping doesn't take extra args)
      results_a =
        for _i <- 1..5 do
          {:ok, r} = Snakepit.execute("ping", %{}, pool_name: :pool_a)
          r
        end

      # Execute multiple requests on pool_b
      results_b =
        for _i <- 1..5 do
          {:ok, r} = Snakepit.execute("ping", %{}, pool_name: :pool_b)
          r
        end

      assert length(results_a) == 5
      assert length(results_b) == 5
    end
  end

  describe "get_stats per pool" do
    test "get_stats returns per-pool statistics" do
      Application.put_env(:snakepit, :pooling_enabled, true)

      Application.put_env(:snakepit, :pools, [
        %{
          name: :stats_pool,
          worker_profile: :process,
          pool_size: 2,
          adapter_module: Snakepit.Adapters.GRPCPython
        }
      ])

      {:ok, _} = Application.ensure_all_started(:snakepit)

      assert_eventually(
        fn ->
          Snakepit.Pool.await_ready(Snakepit.Pool, 5_000) == :ok
        end,
        timeout: 60_000,
        interval: 1_000
      )

      # Get stats for specific pool
      stats = Snakepit.Pool.get_stats(Snakepit.Pool, :stats_pool)
      assert is_map(stats)
      assert Map.has_key?(stats, :workers)
      assert stats.workers == 2

      # Aggregate stats
      aggregate = Snakepit.Pool.get_stats()
      assert is_map(aggregate)
      assert Map.has_key?(aggregate, :workers)
    end
  end
end
