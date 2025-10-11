defmodule Snakepit.GRPCWorkerMockTest do
  use Snakepit.TestCase

  alias Snakepit.TestAdapters.MockGRPCAdapter

  @moduledoc """
  Tests GRPCWorker behavior using mock adapter to avoid real process spawning.
  """

  describe "gRPC worker with mock adapter" do
    test "worker initializes with mock adapter" do
      # Use the test helper which creates a mock worker
      {worker, _worker_id, port} =
        Snakepit.TestHelpers.create_isolated_worker(
          "mock_init_test",
          adapter: MockGRPCAdapter
        )

      # Should have received ready message from mock
      assert_receive {:grpc_ready, ^port}, 100

      # Worker should be alive
      assert Process.alive?(worker)

      # Clean up is handled by test helper's on_exit
    end

    test "mock worker handles commands" do
      worker_id = "mock_cmd_#{System.unique_integer([:positive])}"

      # Create a mock worker
      {:ok, worker} =
        Snakepit.Test.MockGRPCWorker.start_link(
          id: worker_id,
          adapter: MockGRPCAdapter,
          port: 60000,
          test_pid: self()
        )

      # Test ping command
      {:ok, result} = GenServer.call(worker, {:execute, "ping", %{}, 5_000})
      assert result["status"] == "pong"

      # Test echo command
      {:ok, result} = GenServer.call(worker, {:execute, "echo", %{"test" => "data"}, 5_000})
      assert result["echoed"]["test"] == "data"

      # Clean up
      GenServer.stop(worker)
    end

    test "mock worker tracks statistics" do
      worker_id = "mock_stats_#{System.unique_integer([:positive])}"

      {:ok, worker} =
        Snakepit.Test.MockGRPCWorker.start_link(
          id: worker_id,
          adapter: MockGRPCAdapter,
          port: 60001,
          test_pid: self()
        )

      # Wait for grpc_ready from mock
      assert_receive {:grpc_ready, 60001}, 100

      # Execute commands
      for _ <- 1..3 do
        GenServer.call(worker, {:execute, "ping", %{}, 5_000})
      end

      # Check stats
      stats = GenServer.call(worker, :get_stats)
      assert stats.requests == 3
      assert stats.errors == 0

      GenServer.stop(worker)
    end
  end

  describe "worker lifecycle management" do
    test "worker registers and unregisters properly" do
      worker_id = "lifecycle_#{System.unique_integer([:positive])}"

      # Ensure not registered
      assert Registry.lookup(Snakepit.Pool.Registry, worker_id) == []

      # Start worker
      {:ok, worker} =
        Snakepit.Test.MockGRPCWorker.start_link(
          id: worker_id,
          adapter: MockGRPCAdapter,
          port: 60002,
          test_pid: self()
        )

      # Wait for grpc_ready from mock
      assert_receive {:grpc_ready, 60002}, 100

      # Should be registered
      assert [{^worker, _meta}] = Registry.lookup(Snakepit.Pool.Registry, worker_id)

      # Stop worker
      GenServer.stop(worker)

      # Poll until registry is updated (using Supertester pattern)
      assert_eventually(
        fn ->
          Registry.lookup(Snakepit.Pool.Registry, worker_id) == []
        end,
        timeout: 1_000
      )
    end
  end
end
