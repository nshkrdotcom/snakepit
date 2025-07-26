defmodule Snakepit.CoreInfrastructureTest do
  use ExUnit.Case, async: false  # Pool tests need to be sequential
  
  alias Snakepit.GenericWorker
  alias Snakepit.TestAdapters.MockAdapter

  describe "Core Infrastructure" do
    test "GenericWorker can start with mock adapter" do
      # Test that GenericWorker can start independently with mock adapter
      worker_id = "test_worker_#{System.unique_integer([:positive])}"
      
      {:ok, pid} = GenericWorker.start_link(worker_id, MockAdapter)
      
      assert Process.alive?(pid)
      
      # Test basic execution directly via GenServer (since registry isn't available)
      assert {:ok, "pong"} = GenServer.call(pid, {:execute, "ping", %{}, []})
      assert {:ok, "hello"} = GenServer.call(pid, {:execute, "echo", %{}, []})
      
      # Test error handling
      assert {:error, "mock error"} = GenServer.call(pid, {:execute, "error", %{}, []})
      
      # Clean up
      GenServer.stop(pid)
    end
    
    test "MockAdapter implements required behavior" do
      # Test that validation passes - but do it after modules are fully loaded
      # Small delay to ensure compilation is complete
      Process.sleep(100)
      
      assert :ok = Snakepit.Adapter.validate_implementation(MockAdapter)
      
      # Test adapter metadata
      metadata = MockAdapter.get_cognitive_metadata()
      assert metadata.adapter_type == :mock
      assert metadata.test_mode == true
    end
    
    test "Manual pool startup with mock adapters" do
      # Start a pool manually with explicit mock adapter configuration
      pool_opts = [
        size: 2,
        adapter_module: MockAdapter,
        worker_module: GenericWorker,
        name: :test_pool
      ]
      
      {:ok, pool_pid} = Snakepit.Pool.start_link(pool_opts)
      
      # Wait for pool to initialize
      assert :ok = Snakepit.Pool.await_ready(:test_pool, 5_000)
      
      # Test pool execution
      assert {:ok, "pong"} = Snakepit.Pool.execute("ping", %{}, pool: :test_pool)
      assert {:ok, "hello"} = Snakepit.Pool.execute("echo", %{}, pool: :test_pool)
      
      # Test error handling
      assert {:error, "mock error"} = Snakepit.Pool.execute("error", %{}, pool: :test_pool)
      
      # Clean up
      GenServer.stop(pool_pid)
    end
    
    test "Application starts without automatic pooling" do
      # This test passes if the application can start without pooling
      # Since we disabled pooling in test config, Pool should not be running
      assert Process.whereis(Snakepit.Pool) == nil
    end
  end
end