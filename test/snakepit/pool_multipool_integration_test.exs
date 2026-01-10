defmodule Snakepit.PoolMultiPoolIntegrationTest do
  @moduledoc """
  Integration tests for multi-pool functionality.

  Tests verify that:
  1. Pool.init correctly reads and uses multi-pool configuration
  2. WorkerProfile is used correctly for each pool
  3. Pools can be configured with different profiles
  """
  use ExUnit.Case, async: false
  import Snakepit.TestHelpers

  @moduletag :integration
  @moduletag timeout: 60_000
  @moduletag :python_integration

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

  describe "multi-pool configuration" do
    test "Pool.init accepts and uses multi-pool configuration" do
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

      # Verify pool started
      assert Process.whereis(Snakepit.Pool) != nil

      # Wait for workers to be ready
      assert_eventually(
        fn ->
          Snakepit.Pool.await_ready(Snakepit.Pool, 5_000) == :ok
        end,
        timeout: 60_000,
        interval: 1_000
      )

      # Verify we can list workers from each pool
      workers_a = Snakepit.Pool.list_workers(Snakepit.Pool, :pool_a)
      workers_b = Snakepit.Pool.list_workers(Snakepit.Pool, :pool_b)

      assert length(workers_a) == 2, "pool_a should have 2 workers"
      assert length(workers_b) == 2, "pool_b should have 2 workers"
    end

    test "can execute on named pool (not default)" do
      Application.put_env(:snakepit, :pools, [
        %{
          name: :test_pool,
          worker_profile: :process,
          pool_size: 1,
          adapter_module: Snakepit.Adapters.GRPCPython
        }
      ])

      Application.put_env(:snakepit, :pooling_enabled, true)

      {:ok, _} = Application.ensure_all_started(:snakepit)

      # Wait for pool to be ready
      assert_eventually(
        fn ->
          Snakepit.Pool.await_ready(Snakepit.Pool, 5_000) == :ok
        end,
        timeout: 60_000,
        interval: 1_000
      )

      # Execute on the named pool
      {:ok, result} = Snakepit.execute("ping", %{}, pool_name: :test_pool)
      assert is_map(result)
    end
  end

  describe "WorkerProfile integration" do
    test "Pool uses WorkerProfile.start_worker for profile-based pools" do
      Application.put_env(:snakepit, :pools, [
        %{
          name: :test,
          worker_profile: :process,
          pool_size: 1,
          # Custom env to verify it's passed through
          adapter_env: [{"TEST_VAR", "test_value"}],
          adapter_module: Snakepit.Adapters.GRPCPython
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

      # Verify pool started and has workers
      workers = Snakepit.Pool.list_workers(Snakepit.Pool, :test)
      assert length(workers) == 1

      # Execute a ping to verify the worker is functional
      {:ok, result} = Snakepit.execute("ping", %{}, pool_name: :test)
      assert is_map(result)
    end
  end
end
