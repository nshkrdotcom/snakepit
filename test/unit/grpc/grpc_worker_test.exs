defmodule Snakepit.GRPCWorkerTest do
  use Snakepit.TestCase
  import ExUnit.CaptureLog

  alias Snakepit.TestAdapters.MockGRPCAdapter

  describe "gRPC worker lifecycle" do
    setup context do
      # Create isolated worker with unique port
      {worker, _worker_id, port} =
        Snakepit.TestHelpers.create_isolated_worker(
          context.test,
          adapter: MockGRPCAdapter
        )

      # Wait for server ready without sleep
      assert_receive {:grpc_ready, ^port}, 5_000

      on_exit(fn ->
        if Process.alive?(worker) do
          try do
            GenServer.stop(worker)
          catch
            # Already stopped
            :exit, _ -> :ok
          end
        end
      end)

      %{worker: worker, port: port}
    end

    test "worker starts gRPC server and connects", %{worker: worker, port: port} do
      # Check worker is alive
      assert Process.alive?(worker)

      # Get worker state
      state = :sys.get_state(worker)
      assert state.port == port
      assert state.connection != nil
    end

    test "worker handles ping command", %{worker: worker} do
      # Use synchronous call for deterministic behavior
      {:ok, result} = GenServer.call(worker, {:execute, "ping", %{}, 5_000})
      assert result["status"] == "pong"
      assert result["worker_id"] == "test_worker"
    end

    test "worker handles echo command", %{worker: worker} do
      test_data = %{"message" => "Hello, gRPC!", "timestamp" => DateTime.utc_now()}

      {:ok, result} = GenServer.call(worker, {:execute, "echo", test_data, 5_000})
      assert result["echoed"] == test_data
    end

    test "worker tracks statistics", %{worker: worker} do
      # Execute several commands
      for _ <- 1..5 do
        GenServer.call(worker, {:execute, "ping", %{}, 5_000})
      end

      # Check stats
      stats = GenServer.call(worker, :get_stats)
      assert stats.requests == 5
      assert stats.errors == 0
    end

    test "worker handles command timeout", %{worker: worker} do
      # Execute slow operation with short GenServer.call timeout
      # The operation takes 200ms but we only wait 100ms for the GenServer call
      assert catch_exit(
               GenServer.call(worker, {:execute, "slow_operation", %{"delay" => 200}, 5_000}, 100)
             ) ==
               {:timeout,
                {GenServer, :call,
                 [worker, {:execute, "slow_operation", %{"delay" => 200}, 5_000}, 100]}}

      # Worker should still be alive and responsive after timeout
      assert Process.alive?(worker)
      {:ok, result} = GenServer.call(worker, {:execute, "ping", %{}, 5_000}, 5_000)
      assert result["status"] == "pong"
    end

    test "worker survives adapter errors", %{worker: worker} do
      # Capture logs during error handling to trap warnings/errors
      log =
        capture_log(fn ->
          # Send invalid command
          {:error, _reason} = GenServer.call(worker, {:execute, "invalid_command", %{}, 5_000})

          # Worker should still be alive
          assert Process.alive?(worker)

          # Should still handle valid commands
          {:ok, result} = GenServer.call(worker, {:execute, "ping", %{}, 5_000})
          assert result["status"] == "pong"
        end)

      # Assert no critical gRPC server errors during error handling
      refute log =~ "Failed to start gRPC server"
      refute log =~ "GenServer .* terminating"
    end
  end

  describe "worker health checks" do
    setup context do
      # Start worker with short health check interval
      {worker, _worker_id, port} =
        Snakepit.TestHelpers.create_isolated_worker(
          context.test,
          adapter: MockGRPCAdapter,
          health_check_interval: 100
        )

      assert_receive {:grpc_ready, ^port}, 5_000

      on_exit(fn ->
        if Process.alive?(worker) do
          try do
            GenServer.stop(worker)
          catch
            # Already stopped
            :exit, _ -> :ok
          end
        end
      end)

      %{worker: worker}
    end

    test "worker performs periodic health checks", %{worker: worker} do
      # Send a manual health check to the mock worker
      send(worker, :health_check)

      # Ensure health check message was processed (using Supertester pattern)
      :ok = wait_for_genserver_sync(worker, 1_000)

      # Worker should still be alive and responsive
      assert Process.alive?(worker)
      assert_genserver_responsive(worker)
    end
  end

  describe "worker shutdown" do
    setup context do
      {worker, worker_id, port} =
        Snakepit.TestHelpers.create_isolated_worker(
          context.test,
          adapter: MockGRPCAdapter
        )

      assert_receive {:grpc_ready, ^port}, 5_000

      %{worker: worker, worker_id: worker_id}
    end

    test "worker shuts down gracefully", %{worker: worker} do
      # Monitor worker
      ref = Process.monitor(worker)

      # Capture logs during shutdown to trap any warnings/errors
      log =
        capture_log(fn ->
          # Stop worker
          :ok = GenServer.stop(worker, :normal)

          # Should receive DOWN message
          assert_receive {:DOWN, ^ref, :process, ^worker, :normal}
        end)

      # Assert no error logs during normal shutdown
      refute log =~ "Failed to start gRPC server"
      refute log =~ "Attempted to unregister unknown worker"
      refute log =~ "GenServer .* terminating"
    end

    test "worker cleans up resources on shutdown", %{worker: worker, worker_id: worker_id} do
      # Capture logs during resource cleanup to trap warnings/errors
      log =
        capture_log(fn ->
          # Stop worker
          GenServer.stop(worker)

          # Worker should be unregistered
          assert Registry.lookup(Snakepit.Pool.Registry, worker_id) == []
        end)

      # Assert no warnings about unregistering unknown workers
      refute log =~ "Attempted to unregister unknown worker"
    end
  end
end
