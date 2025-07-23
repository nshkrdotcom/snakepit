defmodule SnakepitShowcase.Demos.SessionDemo do
  @moduledoc """
  Demonstrates session management including creation, lifecycle,
  session affinity, and stateful operations.
  """

  def run do
    IO.puts("🔐 Session Management Demo\n")
    
    # Demo 1: Session creation
    session_id = demo_session_creation()
    
    # Demo 2: Stateful operations
    demo_stateful_operations(session_id)
    
    # Demo 3: Session affinity
    demo_session_affinity(session_id)
    
    # Demo 4: Session cleanup
    demo_session_cleanup(session_id)
    
    :ok
  end

  defp demo_session_creation do
    IO.puts("1️⃣ Session Creation")
    
    session_id = "demo_session_#{System.unique_integer()}"
    
    {:ok, result} = Snakepit.execute_in_session(session_id, "init_session", %{
      user_id: 123,
      config: %{
        "model" => "gpt-4",
        "temperature" => 0.7
      }
    })
    
    IO.puts("   Created session: #{session_id}")
    IO.puts("   Initialized at: #{result["timestamp"]}")
    IO.puts("   Worker PID: #{result["worker_pid"]}")
    
    session_id
  end

  defp demo_stateful_operations(session_id) do
    IO.puts("\n2️⃣ Stateful Operations")
    
    # Store some state
    IO.puts("   Storing counter...")
    {:ok, _} = Snakepit.execute_in_session(session_id, "set_counter", %{value: 0})
    
    # Increment counter multiple times
    IO.puts("   Incrementing counter 5 times...")
    Enum.each(1..5, fn i ->
      {:ok, result} = Snakepit.execute_in_session(session_id, "increment_counter", %{})
      IO.puts("     #{i}. Counter value: #{result["value"]}")
    end)
    
    # Get final value
    {:ok, result} = Snakepit.execute_in_session(session_id, "get_counter", %{})
    IO.puts("   Final counter value: #{result["value"]}")
  end

  defp demo_session_affinity(session_id) do
    IO.puts("\n3️⃣ Session Affinity")
    
    # Execute multiple commands to verify same worker
    IO.puts("   Executing 10 commands to verify worker affinity...")
    
    worker_pids = 
      Enum.map(1..10, fn i ->
        {:ok, result} = Snakepit.execute_in_session(session_id, "get_worker_info", %{
          call_number: i
        })
        result["worker_pid"]
      end)
    
    unique_pids = Enum.uniq(worker_pids)
    
    if length(unique_pids) == 1 do
      IO.puts("   ✅ All commands executed on same worker: #{hd(unique_pids)}")
    else
      IO.puts("   ❌ Commands executed on different workers: #{inspect(unique_pids)}")
    end
  end

  defp demo_session_cleanup(session_id) do
    IO.puts("\n4️⃣ Session Cleanup")
    
    IO.puts("   Cleaning up session...")
    {:ok, result} = Snakepit.execute_in_session(session_id, "cleanup", %{})
    
    IO.puts("   Session duration: #{result["duration_ms"]}ms")
    IO.puts("   Commands executed: #{result["command_count"]}")
    IO.puts("   ✅ Session cleaned up successfully")
  end
end