defmodule SnakepitShowcase.Demos.StreamingDemo do
  @moduledoc """
  Demonstrates streaming operations including real-time progress updates,
  chunked data processing, and stream cancellation.
  """

  def run do
    IO.puts("📡 Streaming Operations Demo\n")
    
    # Demo 1: Progress streaming
    demo_progress_streaming()
    
    # Demo 2: Data streaming
    demo_data_streaming()
    
    # Demo 3: Large result streaming
    demo_large_result_streaming()
    
    # Demo 4: Stream cancellation
    demo_stream_cancellation()
    
    :ok
  end

  defp demo_progress_streaming do
    IO.puts("1️⃣ Progress Streaming")
    
    IO.puts("   Processing 10 steps with progress updates...")
    
    :ok = Snakepit.execute_stream("stream_progress", %{steps: 10}, fn chunk ->
      IO.puts("   Step #{chunk["step"]}/#{chunk["total"]}: #{chunk["progress"]}% - #{chunk["message"]}")
    end)
    
    IO.puts("   ✅ Processing complete!")
  end

  defp demo_data_streaming do
    IO.puts("\n2️⃣ Data Streaming")
    
    IO.puts("   Streaming Fibonacci sequence...")
    
    :ok = Snakepit.execute_stream("stream_fibonacci", %{count: 20}, fn chunk ->
      # Only print the first 10 for brevity
      if chunk["index"] <= 10 do
        IO.puts("   Fibonacci ##{chunk["index"]}: #{chunk["value"]}")
      end
    end)
    
    IO.puts("   ... (showing first 10 of 20)")
  end

  defp demo_large_result_streaming do
    IO.puts("\n3️⃣ Large Result Streaming")
    
    IO.puts("   Generating and streaming large dataset...")
    
    chunk_count_ref = :atomics.new(1, [])
    
    :ok = Snakepit.execute_stream("generate_dataset", %{
      rows: 1000,
      chunk_size: 100
    }, fn chunk ->
      count = :atomics.get(chunk_count_ref, 1)
      IO.puts("   Received chunk #{count}: #{chunk["rows_in_chunk"]} rows (total so far: #{chunk["total_rows"]})")
      :atomics.add(chunk_count_ref, 1, 1)
    end)
    
    final_count = :atomics.get(chunk_count_ref, 1) - 1
    IO.puts("   ✅ Received #{final_count} chunks")
  end

  defp demo_stream_cancellation do
    IO.puts("\n4️⃣ Stream Cancellation")
    
    IO.puts("   Starting long-running stream...")
    
    task = Task.async(fn ->
      :ok = Snakepit.execute_stream("infinite_stream", %{delay_ms: 500}, fn chunk ->
        IO.puts("   Received: #{chunk["message"]} at #{chunk["timestamp"]}")
      end)
    end)
    
    # Let it run for a bit
    Process.sleep(2000)
    
    # Cancel the task
    Task.shutdown(task, :brutal_kill)
    
    IO.puts("   ✅ Stream cancelled after receiving messages")
  end
end