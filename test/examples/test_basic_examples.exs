defmodule Snakepit.Test.BasicExamplesTest do
  @moduledoc """
  Tests to verify that our basic examples work correctly.
  """
  
  use ExUnit.Case
  alias Snakepit.TestAdapters.MockAdapter
  
  setup do
    # Save original config
    original_adapter = Application.get_env(:snakepit, :adapter_module)
    original_pooling = Application.get_env(:snakepit, :pooling_enabled)
    
    # Configure for testing with MockAdapter
    Application.put_env(:snakepit, :adapter_module, MockAdapter)
    Application.put_env(:snakepit, :pooling_enabled, true)
    Application.put_env(:snakepit, :pool_config, %{pool_size: 2})
    
    # Start a pool for testing
    {:ok, pool} = Snakepit.Pool.start_link(name: TestExamplePool)
    
    on_exit(fn ->
      if Process.alive?(pool), do: GenServer.stop(pool)
      Application.put_env(:snakepit, :adapter_module, original_adapter)
      Application.put_env(:snakepit, :pooling_enabled, original_pooling)
    end)
    
    %{pool: pool}
  end
  
  describe "basic adapter examples" do
    test "echo command works", %{pool: pool} do
      assert {:ok, "pong"} = Snakepit.execute("ping", %{}, pool: pool)
    end
    
    test "echo with message works", %{pool: pool} do
      assert {:ok, "test message"} = Snakepit.execute("echo", %{"message" => "test message"}, pool: pool)
    end
    
    test "error handling works", %{pool: pool} do
      assert {:error, "mock error"} = Snakepit.execute("error", %{}, pool: pool)
    end
    
    test "concurrent execution works", %{pool: pool} do
      # Launch multiple slow tasks
      tasks = for i <- 1..4 do
        Task.async(fn ->
          start = System.monotonic_time(:millisecond)
          {:ok, result} = Snakepit.execute("slow", %{}, pool: pool)
          elapsed = System.monotonic_time(:millisecond) - start
          {i, result, elapsed}
        end)
      end
      
      results = Task.await_many(tasks, 5000)
      
      # All should complete
      assert length(results) == 4
      for {_i, result, _elapsed} <- results do
        assert result == "completed"
      end
    end
  end
  
  describe "session affinity examples" do
    test "session routing works", %{pool: pool} do
      session_id = "test_session_#{:rand.uniform(1000)}"
      
      # Multiple requests should use same worker
      results = for _ <- 1..3 do
        Snakepit.execute_in_session(session_id, "echo", %{"message" => "session test"})
      end
      
      # All should succeed
      assert Enum.all?(results, fn {:ok, msg} -> msg == "session test" end)
    end
  end
  
  describe "streaming examples" do
    test "streaming works with mock adapter", %{pool: pool} do
      chunks = []
      
      assert :ok = Snakepit.execute_stream("test", %{}, fn chunk ->
        send(self(), {:chunk, chunk})
      end, pool: pool)
      
      # Collect chunks
      assert_receive {:chunk, %{chunk: 1, data: "first"}}
      assert_receive {:chunk, %{chunk: 2, data: "second"}}
      assert_receive {:chunk, %{chunk: 3, data: "final"}}
    end
  end
  
  describe "adapter validation" do
    test "MockAdapter implements all required callbacks" do
      assert :ok = Snakepit.Adapter.validate_implementation(MockAdapter)
    end
    
    test "MockAdapter supports streaming" do
      assert MockAdapter.supports_streaming?() == true
    end
    
    test "MockAdapter provides cognitive metadata" do
      metadata = MockAdapter.get_cognitive_metadata()
      assert metadata.adapter_type == :mock
      assert metadata.test_mode == true
      assert is_list(metadata.mock_features)
    end
  end
end