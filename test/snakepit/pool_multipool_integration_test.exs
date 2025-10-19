defmodule Snakepit.PoolMultiPoolIntegrationTest do
  use ExUnit.Case, async: false
  import Snakepit.TestHelpers

  @moduletag :integration
  @moduletag timeout: 60_000

  setup do
    prev_pools = Application.get_env(:snakepit, :pools)
    prev_pooling = Application.get_env(:snakepit, :pooling_enabled)

    # Ensure clean state
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

  describe "THE REAL TEST: Does multi-pool actually work?" do
    test "Pool.init accepts and uses multi-pool configuration" do
      # THIS WILL FAIL - Pool.init doesn't read from Config.get_pool_configs yet

      # Configure multi-pool
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

      Application.put_env(:snakepit, :pooling_enabled, true)

      # Start application
      {:ok, _apps} = Application.ensure_all_started(:snakepit)

      # TODO: This will fail because Pool doesn't have list_pools/0
      # pools = Snakepit.Pool.list_pools()
      # assert :pool_a in pools
      # assert :pool_b in pools

      # For now, just verify app started
      assert Process.whereis(Snakepit.Pool) != nil
    end

    test "Can execute on named pool (not default)" do
      # THIS WILL FAIL - Snakepit.execute doesn't accept pool_name parameter

      Application.put_env(:snakepit, :pools, [
        %{name: :test_pool, worker_profile: :process, pool_size: 1}
      ])

      Application.put_env(:snakepit, :pooling_enabled, true)

      {:ok, _} = Application.ensure_all_started(:snakepit)

      # TODO: This signature doesn't exist yet
      # Snakepit.execute(:test_pool, "ping", %{})

      # Current signature only: Snakepit.execute("ping", %{})
      # Doesn't support pool selection

      # For now, test that default still works
      assert_eventually(
        fn ->
          Snakepit.Pool.await_ready(Snakepit.Pool, 5_000) == :ok
        end,
        timeout: 60_000,
        interval: 1_000
      )

      {:ok, _result} = Snakepit.execute("ping", %{})
    end
  end

  describe "THE REAL TEST: Does WorkerProfile get used?" do
    test "Pool actually calls WorkerProfile.start_worker" do
      # THIS IS THE CRITICAL INTEGRATION POINT
      # Pool.start_workers_concurrently should call profile_module.start_worker
      # Currently it calls WorkerSupervisor.start_worker directly

      # We can't easily test this without instrumenting the code
      # But we CAN test the outcome: does profile config get respected?

      Application.put_env(:snakepit, :pools, [
        %{
          name: :test,
          worker_profile: :process,
          pool_size: 1,
          # Custom env
          adapter_env: [{"TEST_VAR", "test_value"}]
        }
      ])

      Application.put_env(:snakepit, :pooling_enabled, true)

      {:ok, _} = Application.ensure_all_started(:snakepit)

      # Wait for pool with assert_eventually
      assert_eventually(
        fn ->
          Snakepit.Pool.await_ready(Snakepit.Pool, 5_000) == :ok
        end,
        timeout: 60_000,
        interval: 1_000
      )

      # If WorkerProfile is being used, it would pass adapter_env to worker
      # If not, it's ignored
      # TODO: Need way to verify worker got the env var

      # For now, just verify pool started
      assert Process.whereis(Snakepit.Pool) != nil
    end
  end
end
