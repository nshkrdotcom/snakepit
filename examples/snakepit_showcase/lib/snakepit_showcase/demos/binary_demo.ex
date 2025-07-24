defmodule SnakepitShowcase.Demos.BinaryDemo do
  @moduledoc """
  Demonstrates automatic binary serialization for large data.
  """

  def run do
    IO.puts("🔬 Binary Serialization Demo\n")
    
    # Create a session for our tests
    session_id = "binary_demo_#{System.unique_integer()}"
    
    try do
      # Demo 1: Small tensor (uses JSON)
      demo_small_tensor(session_id)
      
      # Demo 2: Large tensor (uses binary)
      demo_large_tensor(session_id)
      
      # Demo 3: Performance comparison
      demo_performance_comparison(session_id)
      
      # Demo 4: Embeddings
      demo_embeddings(session_id)
    after
      # Ensure proper cleanup
      IO.puts("\n🧹 Cleaning up...")
      Snakepit.execute_in_session(session_id, "cleanup", %{})
      # Give time for cleanup to complete
    end
    
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
    
    # Run the benchmark
    {:ok, result} = Snakepit.execute_in_session(session_id, "benchmark_encoding", %{
      start_kb: 1,
      end_kb: 40,
      step_kb: 10
    })
    
    IO.puts("\n   Size (KB) | Encoding | JSON (ms) | Binary (ms) | Speedup")
    IO.puts("   ----------|----------|-----------|-------------|--------")
    
    Enum.each(result["results"], fn res ->
      IO.puts("   #{pad_number(res["size_kb"], 9)} | #{pad_string(res["encoding"], 8)} | #{pad_number(res["json_time_ms"], 9)} | #{pad_number(res["binary_time_ms"], 11)} | #{res["speedup"]}x")
    end)
  end

  defp demo_embeddings(session_id) do
    IO.puts("\n4️⃣ Embeddings Demo")
    
    # Create embeddings of different sizes
    embedding_configs = [
      {"short text", 128},
      {"medium length text for embedding", 512},
      {"long text that will generate a larger embedding vector", 1024},
      {"very long text with lots of content that will generate a much larger embedding vector for demonstration purposes", 2048}
    ]
    
    IO.puts("\n   Testing embedding sizes...")
    
    Enum.each(embedding_configs, fn {text, dimensions} ->
      {:ok, result} = Snakepit.execute_in_session(session_id, "create_embedding", %{
        text: text,
        dimensions: dimensions
      })
      
      IO.puts("   - #{dimensions}D embedding:")
      IO.puts("     Text: \"#{String.slice(text, 0, 30)}#{if String.length(text) > 30, do: "...", else: ""}\"")
      IO.puts("     Encoding: #{result["encoding"]}")
      IO.puts("     Size: #{result["size_bytes"]} bytes")
      IO.puts("     Norm: #{result["norm"]}")
    end)
  end
  
  defp pad_string(str, len), do: String.pad_trailing(str, len)
  
  defp pad_number(num, len), do: to_string(num) |> String.pad_leading(len)
end