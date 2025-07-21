# Protocol Performance Benchmark
# Run with: mix run bench/protocol_benchmark.exs

alias Snakepit.Bridge.Protocol

defmodule ProtocolBenchmark do
  def run do
    IO.puts("\n🚀 Wire Protocol Performance Benchmark\n")
    
    # Test data of various sizes
    small_data = %{
      "command" => "test",
      "value" => 42,
      "status" => "ok"
    }
    
    medium_data = %{
      "command" => "process",
      "data" => Enum.map(1..100, &(%{"id" => &1, "value" => :rand.uniform(1000)})),
      "metadata" => %{
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "version" => "2.0",
        "tags" => ["test", "benchmark", "performance"]
      }
    }
    
    large_data = %{
      "command" => "batch_process",
      "items" => Enum.map(1..1000, fn i -> 
        %{
          "id" => i,
          "data" => String.duplicate("x", 100),
          "values" => Enum.map(1..10, &(&1 * i)),
          "metadata" => %{"index" => i, "processed" => false}
        }
      end),
      "config" => %{
        "parallel" => true,
        "timeout" => 30000,
        "retries" => 3
      }
    }
    
    binary_data = %{
      "command" => "process_image",
      "image" => :crypto.strong_rand_bytes(1024 * 10), # 10KB binary
      "format" => "png",
      "operations" => ["resize", "crop", "filter"]
    }
    
    # Benchmark each dataset
    IO.puts("📊 Small Data (simple request):")
    benchmark_data(small_data)
    
    IO.puts("\n📊 Medium Data (100 items):")
    benchmark_data(medium_data)
    
    IO.puts("\n📊 Large Data (1000 items):")
    benchmark_data(large_data)
    
    IO.puts("\n📊 Binary Data (10KB image):")
    benchmark_binary_data(binary_data)
  end
  
  defp benchmark_data(data) do
    iterations = 10_000
    
    # JSON encoding
    json_encode_time = :timer.tc(fn ->
      for _ <- 1..iterations do
        Protocol.encode_request(1, "test", data, format: :json)
      end
    end) |> elem(0)
    
    # MessagePack encoding
    msgpack_encode_time = :timer.tc(fn ->
      for _ <- 1..iterations do
        Protocol.encode_request(1, "test", data, format: :msgpack)
      end
    end) |> elem(0)
    
    # Get sample encoded data for size comparison
    json_encoded = Protocol.encode_request(1, "test", data, format: :json)
    msgpack_encoded = Protocol.encode_request(1, "test", data, format: :msgpack)
    
    # Decoding benchmark
    json_response = Jason.encode!(%{
      "id" => 1,
      "success" => true,
      "result" => data,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
    
    {:ok, msgpack_response} = Msgpax.pack(%{
      "id" => 1,
      "success" => true,
      "result" => data,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }, iodata: false)
    
    json_decode_time = :timer.tc(fn ->
      for _ <- 1..iterations do
        Protocol.decode_response(json_response, format: :json)
      end
    end) |> elem(0)
    
    msgpack_decode_time = :timer.tc(fn ->
      for _ <- 1..iterations do
        Protocol.decode_response(msgpack_response, format: :msgpack)
      end
    end) |> elem(0)
    
    # Print results
    IO.puts("  Encoding (#{iterations} iterations):")
    IO.puts("    JSON:       #{format_time(json_encode_time)} (#{json_encode_time / iterations} μs/op)")
    IO.puts("    MessagePack: #{format_time(msgpack_encode_time)} (#{msgpack_encode_time / iterations} μs/op)")
    IO.puts("    Speed-up:    #{Float.round(json_encode_time / msgpack_encode_time, 2)}x")
    
    IO.puts("  Decoding (#{iterations} iterations):")
    IO.puts("    JSON:        #{format_time(json_decode_time)} (#{json_decode_time / iterations} μs/op)")
    IO.puts("    MessagePack: #{format_time(msgpack_decode_time)} (#{msgpack_decode_time / iterations} μs/op)")
    IO.puts("    Speed-up:    #{Float.round(json_decode_time / msgpack_decode_time, 2)}x")
    
    IO.puts("  Size comparison:")
    IO.puts("    JSON:        #{byte_size(json_encoded)} bytes")
    IO.puts("    MessagePack: #{byte_size(msgpack_encoded)} bytes")
    IO.puts("    Compression: #{Float.round((1 - byte_size(msgpack_encoded) / byte_size(json_encoded)) * 100, 1)}%")
  end
  
  defp benchmark_binary_data(data) do
    iterations = 1_000
    
    # For JSON, we need to base64 encode the binary
    json_data = Map.put(data, "image", Base.encode64(data["image"]))
    
    # MessagePack can handle binary directly
    msgpack_data = data
    
    # Encoding
    json_encode_time = :timer.tc(fn ->
      for _ <- 1..iterations do
        Protocol.encode_request(1, "test", json_data, format: :json)
      end
    end) |> elem(0)
    
    msgpack_encode_time = :timer.tc(fn ->
      for _ <- 1..iterations do
        Protocol.encode_request(1, "test", msgpack_data, format: :msgpack)
      end
    end) |> elem(0)
    
    # Get sample encoded data
    json_encoded = Protocol.encode_request(1, "test", json_data, format: :json)
    msgpack_encoded = Protocol.encode_request(1, "test", msgpack_data, format: :msgpack)
    
    # Print results
    IO.puts("  Encoding (#{iterations} iterations):")
    IO.puts("    JSON (base64):  #{format_time(json_encode_time)} (#{json_encode_time / iterations} μs/op)")
    IO.puts("    MessagePack:     #{format_time(msgpack_encode_time)} (#{msgpack_encode_time / iterations} μs/op)")
    IO.puts("    Speed-up:        #{Float.round(json_encode_time / msgpack_encode_time, 2)}x")
    
    IO.puts("  Size comparison:")
    IO.puts("    JSON (base64):  #{byte_size(json_encoded)} bytes")
    IO.puts("    MessagePack:     #{byte_size(msgpack_encoded)} bytes")
    IO.puts("    Size reduction:  #{Float.round((1 - byte_size(msgpack_encoded) / byte_size(json_encoded)) * 100, 1)}%")
  end
  
  defp format_time(microseconds) when microseconds < 1000 do
    "#{microseconds} μs"
  end
  
  defp format_time(microseconds) when microseconds < 1_000_000 do
    "#{Float.round(microseconds / 1000, 2)} ms"
  end
  
  defp format_time(microseconds) do
    "#{Float.round(microseconds / 1_000_000, 2)} s"
  end
end

# Run the benchmark
ProtocolBenchmark.run()