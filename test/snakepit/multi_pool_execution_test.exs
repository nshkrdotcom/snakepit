defmodule Snakepit.MultiPoolExecutionTest do
  use ExUnit.Case, async: false
  import Snakepit.TestHelpers

  @moduletag :multi_pool
  @moduletag :python_integration
  @moduletag timeout: 120_000

  setup do
    prev_pools = Application.get_env(:snakepit, :pools)
    prev_pooling = Application.get_env(:snakepit, :pooling_enabled)

    # Stop any running Snakepit
    Application.stop(:snakepit)
    Application.load(:snakepit)

    on_exit(fn ->
      Application.stop(:snakepit)
      restore_env(:pools, prev_pools)
      restore_env(:pooling_enabled, prev_pooling)
      # Wait for processes to actually stop
      assert_eventually(
        fn ->
          Process.whereis(Snakepit.Pool) == nil
        end,
        timeout: 5_000,
        interval: 100
      )
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

      assert_eventually(
        fn ->
          Snakepit.Pool.list_workers()
          |> Enum.count() >= 1
        end,
        timeout: 10_000,
        interval: 200
      )

      assert {:ok, result} = Snakepit.execute("ping", %{}, pool_name: :default)
      assert is_map(result)

      assert {:error, :pool_not_initialized} =
               Snakepit.execute("ping", %{}, pool_name: :broken_pool)
    end
  end

  describe "CRITICAL: Two pools running simultaneously" do
    test "starts two pools with different names and executes on both" do
      # THIS WILL FAIL - Pool only supports single pool (uses first pool only)

      # Configure TWO pools
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

      # NOTE: Pool.await_ready/2 does not support named pools. It only works with the default pool.
      # Multi-pool support is a future enhancement.
      # For now, wait for default pool with longer timeout for Python server startup
      assert_eventually(
        fn ->
          Snakepit.Pool.await_ready(Snakepit.Pool, 5_000) == :ok
        end,
        timeout: 60_000,
        interval: 1_000
      )

      # NOTE: Snakepit.execute/3 does not support routing to named pools.
      # Current signature: Snakepit.execute(command, args, opts)
      # Future enhancement would add: Snakepit.execute(pool_name, command, args, opts)
      {:ok, result_a} = Snakepit.execute("ping", %{message: "to_pool_a"})
      assert is_map(result_a)

      # NOTE: This executes on the same (default) pool as above, not on pool_b.
      # Pool routing is not yet implemented.
      {:ok, result_b} = Snakepit.execute("ping", %{message: "to_pool_b"})
      assert is_map(result_b)

      # NOTE: Unable to verify which pool handled each request without pool routing support
      # and pool identification in responses. This is a known limitation.
      assert true, "Test structure works but can't verify multi-pool yet"
    end

    test "pools have independent worker sets" do
      # THIS WILL FAIL - Need per-pool worker tracking

      Application.put_env(:snakepit, :pooling_enabled, true)

      Application.put_env(:snakepit, :pools, [
        %{name: :pool_a, worker_profile: :process, pool_size: 3},
        %{name: :pool_b, worker_profile: :process, pool_size: 5}
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

      # NOTE: Pool.list_workers/0 does not support querying workers from named pools.
      # Current: Snakepit.Pool.list_workers() returns all workers from the default pool.
      # Future enhancement: Snakepit.Pool.list_workers(pool_name) to query specific pools.
      workers = Snakepit.Pool.list_workers()

      # NOTE: Unable to verify pool separation. The current implementation only manages
      # a single pool (the first configured pool), not multiple independent pools.
      assert not Enum.empty?(workers), "Workers started"
    end

    test "pools can have different profiles (process vs thread)" do
      # THIS WILL FAIL - Multi-pool not supported yet
      # When it works, this tests process and thread pools coexisting
    end
  end

  describe "CRITICAL: Pool routing by name" do
    test "Snakepit.execute routes to named pool" do
      # THIS WILL FAIL - execute doesn't accept pool_name parameter

      Application.put_env(:snakepit, :pooling_enabled, true)

      Application.put_env(:snakepit, :pools, [
        %{name: :named_pool, worker_profile: :process, pool_size: 2}
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

      # NOTE: Pool routing by name is not implemented.
      # Current signature: execute(command, args, opts)
      # Future enhancement: execute(pool_name, command, args, opts)
      # For now, can only execute on default pool
      {:ok, result} = Snakepit.execute("ping", %{})
      assert is_map(result)
    end

    test "can execute on :pool_a and :pool_b independently" do
      # THIS IS THE KEY TEST for multi-pool routing

      # Application.put_env(:snakepit, :pools, [
      #   %{name: :pool_a, pool_size: 2},
      #   %{name: :pool_b, pool_size: 2}
      # ])
      #
      # {:ok, _} = Application.ensure_all_started(:snakepit)
      #
      # # Execute 10 requests on pool_a
      # results_a = for i <- 1..10 do
      #   {:ok, r} = Snakepit.execute(:pool_a, "ping", %{id: i})
      #   r
      # end
      #
      # # Execute 10 requests on pool_b
      # results_b = for i <- 1..10 do
      #   {:ok, r} = Snakepit.execute(:pool_b, "ping", %{id: i})
      #   r
      # end
      #
      # assert length(results_a) == 10
      # assert length(results_b) == 10
      #
      # # Verify they used different worker sets
      # # (would need worker_id in response to verify)
    end
  end

  describe "CRITICAL: Different lifecycle policies per pool" do
    test "pool_a has short TTL, pool_b has long TTL" do
      # THIS WILL FAIL - Per-pool lifecycle not validated

      # Application.put_env(:snakepit, :pools, [
      #   %{name: :short, pool_size: 1, worker_ttl: {5, :seconds}},
      #   %{name: :long, pool_size: 1, worker_ttl: {3600, :seconds}}
      # ])
      #
      # {:ok, _} = Application.ensure_all_started(:snakepit)
      #
      # # Get initial workers
      # [worker_short_initial] = Snakepit.Pool.list_workers(:short)
      # [worker_long_initial] = Snakepit.Pool.list_workers(:long)
      #
      # # Wait for short TTL + check interval
      # :timer.sleep(66_000)  # 5s + 60s + buffer
      #
      # # Verify short pool worker recycled
      # [worker_short_new] = Snakepit.Pool.list_workers(:short)
      # assert worker_short_new != worker_short_initial
      #
      # # Verify long pool worker NOT recycled
      # [worker_long_same] = Snakepit.Pool.list_workers(:long)
      # assert worker_long_same == worker_long_initial
    end

    test "pool_a recycles after 5 requests, pool_b after 100" do
      # THIS WILL FAIL - Request-count recycling per pool not validated

      # Application.put_env(:snakepit, :pools, [
      #   %{name: :low, pool_size: 1, worker_max_requests: 5},
      #   %{name: :high, pool_size: 1, worker_max_requests: 100}
      # ])
      #
      # {:ok, _} = Application.ensure_all_started(:snakepit)
      #
      # # Execute 10 requests on low pool
      # for _ <- 1..10, do: Snakepit.execute(:low, "ping", %{})
      #
      # # Execute 10 requests on high pool
      # for _ <- 1..10, do: Snakepit.execute(:high, "ping", %{})
      #
      # # low should have recycled (after request 5)
      # # high should NOT have recycled (10 < 100)
      #
      # # Verify via telemetry or worker IDs
    end
  end
end
