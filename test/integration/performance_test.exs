defmodule PerformanceTest do
  use ExUnit.Case
  import BridgeTestHelper
  
  @moduletag :integration
  @moduletag :performance
  
  setup do
    channel = start_bridge()
    session_id = create_test_session(channel)
    
    {:ok, channel: channel, session_id: session_id}
  end
  
  describe "latency benchmarks" do
    test "variable get latency", %{channel: channel, session_id: session_id} do
      # Register variable
      {:ok, _, _} = Snakepit.GRPC.Client.register_variable(
        channel, session_id, "perf_var", :float, 1.0
      )
      
      # Warmup
      for _ <- 1..10 do
        Snakepit.GRPC.Client.get_variable(channel, session_id, "perf_var")
      end
      
      # Measure
      latencies = for _ <- 1..100 do
        start = System.monotonic_time(:microsecond)
        {:ok, _} = Snakepit.GRPC.Client.get_variable(channel, session_id, "perf_var")
        System.monotonic_time(:microsecond) - start
      end
      
      avg_latency = Enum.sum(latencies) / length(latencies)
      p95_latency = Enum.at(Enum.sort(latencies), 95)
      
      IO.puts("Get latency - Avg: #{avg_latency}μs, P95: #{p95_latency}μs")
      
      # Should be under 5ms average
      assert avg_latency < 5000
    end
    
    test "streaming throughput", %{channel: channel, session_id: session_id} do
      # Register variable
      {:ok, _, _} = Snakepit.GRPC.Client.register_variable(
        channel, session_id, "stream_var", :integer, 0
      )
      
      # Start watcher
      {:ok, stream} = Snakepit.GRPC.Client.watch_variables(
        channel,
        session_id,
        ["stream_var"],
        include_initial: false
      )
      
      # Count updates
      test_pid = self()
      counter = Task.async(fn ->
        count = stream
        |> Stream.take_while(fn _ -> true end)
        |> Enum.reduce(0, fn {:ok, _update}, acc ->
          if acc == 0, do: send(test_pid, :first_update)
          acc + 1
        end)
        
        count
      end)
      
      # Wait for stream to establish
      assert_receive :first_update, 5000
      
      # Send rapid updates
      start_time = System.monotonic_time(:millisecond)
      
      for i <- 1..1000 do
        Snakepit.GRPC.Client.set_variable(channel, session_id, "stream_var", i)
      end
      
      # Wait a bit for propagation
      Process.sleep(1000)
      
      # Check throughput
      elapsed = System.monotonic_time(:millisecond) - start_time
      updates_per_second = 1000 / (elapsed / 1000)
      
      IO.puts("Streaming throughput: #{updates_per_second} updates/second")
      
      # Should handle at least 100 updates/second
      assert updates_per_second > 100
      
      Task.shutdown(counter)
    end
  end
end