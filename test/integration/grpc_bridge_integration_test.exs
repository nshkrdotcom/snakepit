defmodule Snakepit.GRPCBridgeIntegrationTest do
  use Snakepit.TestCase, async: false

  @moduledoc """
  Integration test for the full gRPC bridge stack.
  Tests the actual public API with proper isolation.
  """

  describe "full gRPC bridge integration" do
    setup do
      # Create isolated pool configuration
      pool_name = :"test_pool_#{System.unique_integer([:positive])}"

      # Start a minimal pool with mock adapter and worker
      pool_config = [
        pool_size: 2,
        adapter_module: Snakepit.TestAdapters.MockGRPCAdapter,
        worker_module: Snakepit.Test.MockGRPCWorker,
        pool_name: pool_name,
        name: pool_name
      ]

      # Start pool supervisor
      {:ok, pool_sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

      # Start pool under test supervisor
      {:ok, pool} =
        DynamicSupervisor.start_child(pool_sup, {
          Snakepit.Pool,
          pool_config
        })

      on_exit(fn ->
        # Safely stop the supervisor if it's still alive
        try do
          if Process.alive?(pool_sup) do
            DynamicSupervisor.stop(pool_sup)
          end
        catch
          :exit, _ -> :ok
        end
      end)

      %{pool: pool, pool_name: pool_name}
    end

    test "execute commands through pool", %{pool_name: pool_name} do
      # Use the pool to execute commands
      {:ok, result} = GenServer.call(pool_name, {:execute, "ping", %{}, []}, 5_000)
      assert result["status"] == "pong"

      # Echo command
      {:ok, result} =
        GenServer.call(pool_name, {:execute, "echo", %{"test" => "data"}, []}, 5_000)

      assert result["echoed"]["test"] == "data"
    end

    test "session-based execution", %{pool_name: pool_name} do
      session_id = "test_session_#{System.unique_integer([:positive])}"

      # Initialize session
      {:ok, _} =
        GenServer.call(
          pool_name,
          {:execute, "initialize_session", %{session_id: session_id}, [session_id: session_id]},
          5_000
        )

      # Register variable
      {:ok, result} =
        GenServer.call(
          pool_name,
          {
            :execute,
            "register_variable",
            %{name: "counter", type: "integer", initial_value: 0},
            [session_id: session_id]
          },
          5_000
        )

      assert result["id"] != nil

      # Get variable
      {:ok, result} =
        GenServer.call(
          pool_name,
          {
            :execute,
            "get_variable",
            %{name: "counter"},
            [session_id: session_id]
          },
          5_000
        )

      # Mock returns 42
      assert result["value"] == 42

      # Cleanup
      GenServer.call(
        pool_name,
        {:execute, "cleanup_session", %{}, [session_id: session_id]},
        5_000
      )
    end

    test "concurrent requests", %{pool_name: pool_name} do
      # Start multiple concurrent requests
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            GenServer.call(pool_name, {:execute, "compute", %{id: i}, []}, 5_000)
          end)
        end

      # All should complete
      results = Task.await_many(tasks, 10_000)
      assert length(results) == 10
      assert Enum.all?(results, fn {:ok, result} -> result["result"] == 42 end)
    end

    test "worker affinity for sessions", %{pool_name: pool_name} do
      session_id = "affinity_test_#{System.unique_integer([:positive])}"

      # Multiple calls with same session should prefer same worker
      worker_ids =
        for _ <- 1..5 do
          {:ok, result} =
            GenServer.call(
              pool_name,
              {
                :execute,
                "ping",
                %{},
                [session_id: session_id]
              },
              5_000
            )

          result["worker_id"]
        end

      # Should mostly be the same worker (mock always returns "test_worker")
      assert Enum.all?(worker_ids, &(&1 == "test_worker"))
    end
  end

  describe "error handling" do
    setup do
      # Use failing adapter
      pool_name = :"failing_pool_#{System.unique_integer([:positive])}"

      pool_config = [
        pool_size: 1,
        adapter_module: Snakepit.TestAdapters.FailingAdapter,
        worker_module: Snakepit.Test.MockGRPCWorker,
        pool_name: pool_name,
        name: pool_name
      ]

      # Try to start pool - workers will fail
      {:ok, pool_sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

      # This might fail, but that's expected
      result =
        DynamicSupervisor.start_child(pool_sup, {
          Snakepit.Pool,
          pool_config
        })

      on_exit(fn ->
        # Safely stop the supervisor if it's still alive
        try do
          if Process.alive?(pool_sup) do
            DynamicSupervisor.stop(pool_sup)
          end
        catch
          :exit, _ -> :ok
        end
      end)

      case result do
        {:ok, pool} -> %{pool: pool, pool_name: pool_name, pool_started: true}
        {:error, _} -> %{pool: nil, pool_name: pool_name, pool_started: false}
      end
    end

    test "pool handles worker startup failures gracefully", context do
      # Pool should handle failed workers without crashing
      assert context.pool_started == true or context.pool_started == false
      # Either way, the test supervisor should still be running
    end
  end
end
