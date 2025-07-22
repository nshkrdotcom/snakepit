defmodule ServerStartupTest do
  use ExUnit.Case
  import BridgeTestHelper
  
  @moduletag :integration
  
  describe "server startup" do
    test "detects GRPC_READY message via stdout" do
      # Start fresh
      cleanup_bridge()
      
      # Capture logs to verify stdout monitoring
      log_capture = ExUnit.CaptureLog.capture_log(fn ->
        {:ok, _pid} = Snakepit.GRPC.Worker.start_link()
        {:ok, _channel} = Snakepit.GRPC.Worker.await_ready(10_000)
      end)
      
      # Verify we saw the ready message
      assert log_capture =~ "Python gRPC server ready on port"
      assert log_capture =~ "GRPC_READY:"
    end
    
    test "handles server crash and restart" do
      channel = start_bridge()
      
      # Get the Python process port
      %{python_port: port} = :sys.get_state(Snakepit.GRPC.Worker)
      
      # Kill the Python process
      Port.close(port)
      
      # Wait a bit
      Process.sleep(100)
      
      # Worker should detect the crash
      refute Process.alive?(Process.whereis(Snakepit.GRPC.Worker))
    end
    
    test "concurrent startup requests" do
      cleanup_bridge()
      
      # Start multiple processes trying to connect
      tasks = for _ <- 1..5 do
        Task.async(fn ->
          {:ok, _pid} = Snakepit.GRPC.Worker.start_link()
          Snakepit.GRPC.Worker.await_ready(10_000)
        end)
      end
      
      # All should succeed with the same channel
      results = Task.await_many(tasks, 15_000)
      channels = Enum.map(results, fn {:ok, ch} -> ch end)
      
      # Should all be the same channel
      assert length(Enum.uniq(channels)) == 1
    end
  end
end