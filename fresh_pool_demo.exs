# Fresh Pool Demo - Ensures pool starts properly
# Run with: MIX_ENV=test elixir -S mix run fresh_pool_demo.exs

IO.puts("🏊‍♂️ Fresh Pool Demo")
IO.puts("Testing Snakepit pool functionality with proper startup\n")

# The key insight: in MIX_ENV=test, we need to override the config
# BEFORE the application module is loaded and started

# Step 1: Stop any existing application
try do
  Application.stop(:snakepit)
  Process.sleep(100)
rescue
  _ -> :ok
end

# Step 2: Configure for pool mode BEFORE starting
IO.puts("📋 Configuring pool settings...")
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :adapter_module, Snakepit.TestAdapters.MockAdapter)
Application.put_env(:snakepit, :pool_config, %{pool_size: 2})

# Step 3: Start application with pool config
IO.puts("📋 Starting Snakepit with pool enabled...")
case Application.ensure_all_started(:snakepit) do
  {:ok, _} -> IO.puts("✅ Application started")
  {:error, reason} -> 
    IO.puts("❌ Application start failed: #{inspect(reason)}")
    System.halt(1)
end

# Step 4: Verify pool is running
IO.puts("⏳ Verifying pool status...")
case Process.whereis(Snakepit.Pool) do
  nil ->
    IO.puts("❌ Pool process not found")
    IO.puts("💡 This means pooling was not enabled during application start")
    IO.puts("💡 The config must be set before the first Application.ensure_all_started call")
    System.halt(1)
  pid ->
    IO.puts("✅ Pool process running: #{inspect(pid)}")
end

# Step 5: Wait for pool initialization
IO.puts("⏳ Waiting for pool to be ready...")
case Snakepit.Pool.await_ready(Snakepit.Pool, 10_000) do
  :ok ->
    IO.puts("✅ Pool is ready!")
    
    # Now run the demos
    IO.puts("\n🔧 Demo 1: Basic Pool Execution")
    {:ok, result} = Snakepit.execute("ping", %{})
    IO.puts("✅ Basic execution: #{inspect(result)}")
    
    {:ok, result} = Snakepit.execute("echo", %{"message" => "Hello Fresh Pool!"})
    IO.puts("✅ Echo execution: #{inspect(result)}")
    
    IO.puts("\n🔗 Demo 2: Session Affinity")
    session_id = "fresh_session"
    
    for i <- 1..3 do
      {:ok, result} = Snakepit.execute_in_session(session_id, "ping", %{iteration: i})
      IO.puts("✅ Session call #{i}: #{inspect(result)}")
    end
    
    IO.puts("\n📊 Demo 3: Pool Statistics")
    stats = Snakepit.get_stats()
    IO.puts("✅ Pool stats: #{stats.requests} requests processed")
    
    IO.puts("\n✨ Demo 4: Session Helpers")
    {:ok, result} = Snakepit.SessionHelpers.execute_in_context(
      "fresh_helper_session",
      "echo",
      %{"message" => "Fresh session helper"}
    )
    IO.puts("✅ Session helper: #{inspect(result)}")
    
    IO.puts("\n🎉 Fresh Pool Demo Complete!")
    IO.puts("✅ ALL POOL FUNCTIONALITY IS WORKING!")
    
  {:error, :timeout} ->
    IO.puts("❌ Pool initialization timeout")
    IO.puts("This indicates workers failed to start properly")
    System.halt(1)
end