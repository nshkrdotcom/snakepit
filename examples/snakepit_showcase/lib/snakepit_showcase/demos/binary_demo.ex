defmodule SnakepitShowcase.Demos.BinaryDemo do
  @moduledoc """
  Demonstrates automatic binary serialization for large data.
  """

  def run do
    IO.puts("🔬 Binary Serialization Demo\n")
    
    # Create a session for our tests
    session_id = "binary_demo_#{System.unique_integer()}"
    
    # Demo 1: Small tensor (uses JSON)
    demo_small_tensor(session_id)
    
    # Demo 2: Large tensor (uses binary)
    demo_large_tensor(session_id)
    
    # Demo 3: Performance comparison
    demo_performance_comparison(session_id)
    
    # Demo 4: Embeddings
    demo_embeddings(session_id)
    
    # Cleanup
    Snakepit.execute_in_session(session_id, "cleanup", %{})
    
    :ok
  end

  defp demo_small_tensor(session_id) do
    IO.puts("\n1️⃣ Small Tensor (JSON Encoding)")
    
    # Create a small tensor (< 10KB)
    start_time = System.monotonic_time(:millisecond)
    
    {:ok, result} = Snakepit.execute_in_session(session_id, "create_tensor", %{
      name: "small_tensor",
      shape: [10, 10],
      size_bytes: 800  # 100 floats * 8 bytes
    })
    
    elapsed = System.monotonic_time(:millisecond) - start_time
    
    IO.puts("   Created: #{result["name"]}")
    IO.puts("   Shape: #{inspect(result["shape"])}")
    IO.puts("   Size: #{result["size_bytes"]} bytes")
    IO.puts("   Encoding: #{result["encoding"]}")
    IO.puts("   Time: #{elapsed}ms")
  end

  defp demo_large_tensor(session_id) do
    IO.puts("\n2️⃣ Large Tensor (Binary Encoding)")
    
    # Create a large tensor (> 10KB)
    start_time = System.monotonic_time(:millisecond)
    
    {:ok, result} = Snakepit.execute_in_session(session_id, "create_tensor", %{
      name: "large_tensor",
      shape: [100, 100],
      size_bytes: 80_000  # 10,000 floats * 8 bytes
    })
    
    elapsed = System.monotonic_time(:millisecond) - start_time
    
    IO.puts("   Created: #{result["name"]}")
    IO.puts("   Shape: #{inspect(result["shape"])}")
    IO.puts("   Size: #{result["size_bytes"]} bytes")
    IO.puts("   Encoding: #{result["encoding"]}")
    IO.puts("   Time: #{elapsed}ms")
  end

  defp demo_performance_comparison(session_id) do
    IO.puts("\n3️⃣ Performance Comparison")
    
    sizes = [
      {[10, 10], "100 elements (800B)"},
      {[50, 50], "2,500 elements (20KB)"},
      {[100, 100], "10,000 elements (80KB)"},
      {[200, 200], "40,000 elements (320KB)"}
    ]
    
    IO.puts("\n   Shape      | Size       | JSON (ms) | Binary (ms) | Speedup")
    IO.puts("   -----------|------------|-----------|-------------|--------")
    
    Enum.each(sizes, fn {shape, desc} ->
      # Force JSON encoding
      json_time = measure_encoding(session_id, shape, false)
      
      # Force binary encoding
      binary_time = measure_encoding(session_id, shape, true)
      
      speedup = if binary_time > 0, do: json_time / binary_time, else: 0
      
      IO.puts("   #{format_shape(shape)} | #{pad_string(desc, 10)} | #{pad_number(json_time, 9)} | #{pad_number(binary_time, 11)} | #{:io_lib.format("~.1fx", [speedup])}")
    end)
  end

  defp demo_embeddings(session_id) do
    IO.puts("\n4️⃣ Embeddings Demo")
    
    # Create embeddings of different sizes
    embedding_sizes = [128, 512, 1024, 2048]
    
    IO.puts("\n   Testing embedding sizes...")
    
    Enum.each(embedding_sizes, fn size ->
      {:ok, result} = Snakepit.execute_in_session(session_id, "create_embedding", %{
        name: "embedding_#{size}",
        dimensions: size,
        batch_size: 32
      })
      
      IO.puts("   - #{size}D embedding (batch of 32):")
      IO.puts("     Encoding: #{result["encoding"]}")
      IO.puts("     Total size: #{result["total_bytes"]} bytes")
      IO.puts("     Processing time: #{result["time_ms"]}ms")
    end)
  end

  defp measure_encoding(session_id, shape, force_binary) do
    start_time = System.monotonic_time(:millisecond)
    
    Snakepit.execute_in_session(session_id, "benchmark_encoding", %{
      shape: shape,
      force_binary: force_binary
    })
    
    System.monotonic_time(:millisecond) - start_time
  end

  defp format_shape([x, y]), do: "[#{x}, #{y}]" |> String.pad_trailing(9)
  
  defp pad_string(str, len), do: String.pad_trailing(str, len)
  
  defp pad_number(num, len), do: to_string(num) |> String.pad_leading(len)
end