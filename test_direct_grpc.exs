#!/usr/bin/env elixir

# Direct gRPC test bypassing Snakepit pool
Mix.install([
  {:snakepit, path: "."},
  {:grpc, "~> 0.8"},
  {:protobuf, "~> 0.12"}
])

require Logger
Logger.configure(level: :debug)

defmodule DirectGRPCTest do
  def test_streaming do
    IO.puts("\n🔍 Direct gRPC Streaming Test")
    IO.puts("=" |> String.duplicate(50))
    
    # Start a Python gRPC server directly
    port = 50061
    script_path = Path.join([Application.app_dir(:snakepit), "priv", "python", "grpc_bridge.py"])
    
    IO.puts("1️⃣ Starting Python gRPC server on port #{port}...")
    
    port_ref = Port.open({:spawn_executable, System.find_executable("python3")}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: [script_path, "--port", "#{port}", "--adapter", "snakepit_bridge.adapters.grpc_streaming.GRPCStreamingHandler"]
    ])
    
    # Wait for server to start
    Process.sleep(2000)
    
    IO.puts("2️⃣ Connecting to gRPC server...")
    
    case GRPC.Stub.connect("localhost:#{port}") do
      {:ok, channel} ->
        IO.puts("✅ Connected to gRPC server")
        
        IO.puts("\n3️⃣ Creating ExecuteRequest...")
        request = %Snakepit.Grpc.ExecuteRequest{
          command: "ping_stream",
          args: %{
            "count" => Jason.encode!(3),
            "interval" => Jason.encode!(0.2)
          },
          timeout_ms: 10000,
          request_id: "test_#{:rand.uniform(9999)}"
        }
        
        IO.puts("Request: #{inspect(request)}")
        
        IO.puts("\n4️⃣ Calling execute_stream...")
        
        case Snakepit.Grpc.SnakepitBridge.Stub.execute_stream(channel, request, timeout: 10000) do
          {:ok, stream} ->
            IO.puts("✅ Got stream: #{inspect(stream)}")
            
            IO.puts("\n5️⃣ Attempting to consume stream...")
            
            try do
              stream
              |> Enum.each(fn element ->
                IO.puts("📥 Received: #{inspect(element)}")
              end)
              
              IO.puts("\n✅ Stream consumed successfully!")
            rescue
              e ->
                IO.puts("\n❌ Error consuming stream: #{inspect(e)}")
                IO.puts("Stacktrace:")
                Exception.format_stacktrace(__STACKTRACE__) |> IO.puts()
            end
            
          {:error, reason} ->
            IO.puts("❌ Failed to create stream: #{inspect(reason)}")
        end
        
        GRPC.Stub.disconnect(channel)
        
      {:error, reason} ->
        IO.puts("❌ Failed to connect: #{inspect(reason)}")
    end
    
    # Clean up
    Port.close(port_ref)
  end
end

DirectGRPCTest.test_streaming()