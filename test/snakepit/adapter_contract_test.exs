defmodule Snakepit.AdapterContractTest do
  @moduledoc """
  Tests the Snakepit.Adapter behavior contract.
  
  This ensures all adapters properly implement the required interface
  and validates optional callbacks work as expected.
  """
  
  use ExUnit.Case
  alias Snakepit.Adapter
  
  describe "adapter validation" do
    test "validates required callbacks" do
      defmodule ValidAdapter do
        @behaviour Snakepit.Adapter
        def execute(_cmd, _args, _opts), do: {:ok, "result"}
      end
      
      assert :ok = Adapter.validate_implementation(ValidAdapter)
    end
    
    test "detects missing required callbacks" do
      defmodule InvalidAdapter do
        # Missing execute/3
      end
      
      assert {:error, [{:execute, 3}]} = Adapter.validate_implementation(InvalidAdapter)
    end
    
    test "handles nil adapter" do
      assert {:error, [:no_adapter_configured]} = Adapter.validate_implementation(nil)
    end
    
    test "handles module load failures" do
      assert {:error, {:module_load_failed, _}} = 
        Adapter.validate_implementation(NonExistentModule)
    end
  end
  
  describe "adapter behavior compliance" do
    test "mock adapter implements all callbacks correctly" do
      alias Snakepit.TestAdapters.MockAdapter
      
      # Required callback
      assert {:ok, "pong"} = MockAdapter.execute("ping", %{}, [])
      assert {:error, "mock error"} = MockAdapter.execute("error", %{}, [])
      
      # Optional callbacks
      assert {:ok, _state} = MockAdapter.init([])
      assert :ok = MockAdapter.terminate(:normal, %{})
      assert {:ok, _pid} = MockAdapter.start_worker(%{}, "worker_1")
      assert true = MockAdapter.supports_streaming?()
      
      # Streaming
      callback = fn chunk -> send(self(), {:chunk, chunk}) end
      assert :ok = MockAdapter.execute_stream("test", %{}, callback, [])
      
      # Verify chunks received
      assert_receive {:chunk, %{chunk: 1, data: "first"}}
      assert_receive {:chunk, %{chunk: 2, data: "second"}}
      assert_receive {:chunk, %{chunk: 3, data: "final"}}
    end
  end
  
  describe "cognitive metadata" do
    test "default cognitive metadata has expected structure" do
      metadata = Adapter.default_cognitive_metadata()
      
      assert is_list(metadata.cognitive_capabilities)
      assert is_map(metadata.performance_characteristics)
      assert is_map(metadata.resource_requirements)
      assert is_list(metadata.optimization_hints)
      
      # Verify performance characteristics
      assert is_integer(metadata.performance_characteristics.typical_latency_ms)
      assert is_integer(metadata.performance_characteristics.throughput_ops_per_sec)
      assert metadata.performance_characteristics.resource_intensity in [:low, :medium, :high]
    end
    
    test "mock adapter provides cognitive metadata" do
      alias Snakepit.TestAdapters.MockAdapter
      
      metadata = MockAdapter.get_cognitive_metadata()
      assert metadata.adapter_type == :mock
      assert metadata.test_mode == true
      assert is_list(metadata.mock_features)
    end
  end
  
  describe "performance metrics" do
    test "adapter accepts performance metrics" do
      alias Snakepit.TestAdapters.MockAdapter
      
      metrics = %{
        latency_ms: 42,
        success: true,
        command: "test"
      }
      
      context = %{
        session_id: "test_session",
        worker_id: "worker_1"
      }
      
      assert :ok = MockAdapter.report_performance_metrics(metrics, context)
    end
  end
end