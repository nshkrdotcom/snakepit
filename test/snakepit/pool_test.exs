defmodule Snakepit.PoolTest do
  use ExUnit.Case
  alias Snakepit.Pool
  import ExUnit.CaptureLog

  # Mock adapter for testing
  defmodule MockAdapter do
    @behaviour Snakepit.Adapter

    def execute("ping", _args, _opts), do: {:ok, "pong"}
    def execute("error", _args, _opts), do: {:error, "simulated error"}
    def execute("slow", %{delay: delay}, _opts) do
      Process.sleep(delay)
      {:ok, "completed"}
    end
    def execute("get_worker_id", _args, opts) do
      {:ok, inspect(opts[:worker_pid])}
    end
    def execute("crash", _args, _opts) do
      raise "Simulated crash"
    end

    def uses_grpc?, do: false
    def supports_streaming?, do: false
    def init(_config), do: {:ok, %{}}
    def terminate(_reason, _state), do: :ok
    def start_worker(_state, worker_id) do
      {:ok, spawn(fn -> Process.sleep(:infinity) end)}
    end
  end

  setup do
    # Configure mock adapter
    original_adapter = Application.get_env(:snakepit, :adapter_module)
    Application.put_env(:snakepit, :adapter_module, MockAdapter)
    
    {:ok, pool} = Pool.start_link(size: 2, name: TestPool)
    
    on_exit(fn ->
      if Process.alive?(pool) do
        GenServer.stop(pool)
      end
      Application.put_env(:snakepit, :adapter_module, original_adapter)
    end)
    
    %{pool: pool}
  end

  describe "pool initialization" do
    test "starts with configured number of workers", %{pool: pool} do
      state = :sys.get_state(pool)
      assert map_size(state.workers) == 2
      assert length(state.available_workers) == 2
      assert state.busy_workers == MapSet.new()
    end

    test "validates minimum pool size" do
      assert {:error, :invalid_pool_size} = Pool.start_link(size: 0, name: InvalidPool)
    end

    test "validates maximum pool size" do
      assert {:error, :invalid_pool_size} = Pool.start_link(size: 101, name: InvalidPool)
    end

    test "registers pool with given name" do
      assert Process.whereis(TestPool) != nil
    end
  end

  describe "command execution" do
    test "executes commands on available workers", %{pool: pool} do
      assert {:ok, "pong"} = Pool.execute("ping", %{}, pool: pool)
    end

    test "handles adapter errors gracefully", %{pool: pool} do
      assert {:error, "simulated error"} = Pool.execute("error", %{}, pool: pool)
    end

    test "queues requests when all workers are busy", %{pool: pool} do
      # Start two slow tasks to occupy both workers
      task1 = Task.async(fn -> Pool.execute("slow", %{delay: 100}, pool: pool) end)
      task2 = Task.async(fn -> Pool.execute("slow", %{delay: 100}, pool: pool) end)
      
      # Give tasks time to start
      Process.sleep(10)
      
      # Third request should queue
      task3 = Task.async(fn -> Pool.execute("ping", %{}, pool: pool) end)
      
      # Verify queue state
      state = :sys.get_state(pool)
      assert MapSet.size(state.busy_workers) == 2
      assert :queue.len(state.request_queue) > 0
      
      # Wait for all tasks to complete
      assert {:ok, "completed"} = Task.await(task1)
      assert {:ok, "completed"} = Task.await(task2)
      assert {:ok, "pong"} = Task.await(task3)
    end

    test "handles worker crashes and restarts", %{pool: pool} do
      # Execute a command that will crash
      log = capture_log(fn ->
        assert {:error, _} = Pool.execute("crash", %{}, pool: pool)
      end)
      
      assert log =~ "Worker crashed"
      
      # Pool should still be functional with restarted worker
      Process.sleep(50) # Allow restart
      assert {:ok, "pong"} = Pool.execute("ping", %{}, pool: pool)
      
      # Should still have correct number of workers
      state = :sys.get_state(pool)
      assert map_size(state.workers) == 2
    end
  end

  describe "session affinity" do
    test "routes session requests to same worker", %{pool: pool} do
      session_id = "test_session_#{:rand.uniform(1000)}"
      
      # Execute multiple commands in same session
      results = for _i <- 1..5 do
        Pool.execute("get_worker_id", %{}, pool: pool, session_id: session_id)
      end
      
      # Extract worker IDs
      worker_ids = Enum.map(results, fn {:ok, worker_id} -> worker_id end)
      
      # All should use same worker
      assert length(Enum.uniq(worker_ids)) == 1
    end

    test "falls back to load balancing when session worker is busy", %{pool: pool} do
      session_id = "busy_session_#{:rand.uniform(1000)}"
      
      # Get initial worker for session
      {:ok, worker1} = Pool.execute("get_worker_id", %{}, pool: pool, session_id: session_id)
      
      # Start long-running task on session worker
      task = Task.async(fn -> 
        Pool.execute("slow", %{delay: 100}, pool: pool, session_id: session_id)
      end)
      
      Process.sleep(10) # Let first task start
      
      # Second request should use different worker
      {:ok, worker2} = Pool.execute("get_worker_id", %{}, pool: pool, session_id: session_id)
      
      # Should be different workers
      assert worker1 != worker2
      
      Task.await(task)
    end
  end

  describe "pool statistics" do
    test "tracks execution statistics", %{pool: pool} do
      # Execute several commands
      Pool.execute("ping", %{}, pool: pool)
      Pool.execute("error", %{}, pool: pool)
      Pool.execute("ping", %{}, pool: pool)
      
      stats = Pool.get_stats(pool)
      
      assert stats.total_requests == 3
      assert stats.successful_requests == 2
      assert stats.failed_requests == 1
      assert stats.total_workers == 2
      assert stats.available_workers == 2
      assert stats.busy_workers == 0
    end
  end

  describe "telemetry integration" do
    test "emits telemetry events for execution" do
      ref = make_ref()
      
      :telemetry.attach(
        "test-#{ref}",
        [:snakepit, :pool, :execution, :stop],
        fn _event, measurements, metadata, _config ->
          send(self(), {:telemetry, measurements, metadata})
        end,
        nil
      )
      
      Pool.execute("ping", %{}, pool: TestPool)
      
      assert_receive {:telemetry, measurements, metadata}, 1000
      
      assert is_integer(measurements.duration)
      assert metadata.command == "ping"
      assert metadata.success == true
      
      :telemetry.detach("test-#{ref}")
    end

    test "emits telemetry for errors" do
      ref = make_ref()
      
      :telemetry.attach(
        "test-error-#{ref}",
        [:snakepit, :pool, :execution, :stop],
        fn _event, measurements, metadata, _config ->
          send(self(), {:telemetry, measurements, metadata})
        end,
        nil
      )
      
      Pool.execute("error", %{}, pool: TestPool)
      
      assert_receive {:telemetry, measurements, metadata}, 1000
      
      assert metadata.command == "error"
      assert metadata.success == false
      assert metadata.error == "simulated error"
      
      :telemetry.detach("test-error-#{ref}")
    end
  end

  describe "pool lifecycle" do
    test "gracefully shuts down pool" do
      {:ok, pool} = Pool.start_link(size: 1, name: ShutdownPool)
      
      # Execute a slow task
      task = Task.async(fn -> Pool.execute("slow", %{delay: 50}, pool: pool) end)
      
      Process.sleep(10) # Let task start
      
      # Stop pool (should wait for task to complete)
      :ok = GenServer.stop(pool, :normal, 5000)
      
      # Task should have completed
      assert {:ok, "completed"} = Task.await(task)
      
      # Pool should be stopped
      assert Process.whereis(ShutdownPool) == nil
    end
  end
end