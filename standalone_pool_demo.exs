# Standalone Pool Demo - Fresh session demonstration
# This script shows how to use Snakepit in a completely fresh session
# Run with: elixir standalone_pool_demo.exs

IO.puts("🏊‍♂️ Standalone Pool Demo")
IO.puts("Testing Snakepit with fresh application start\n")

# Configure BEFORE any modules are loaded
Mix.install([
  {:snakepit, path: "."}
])

# Set configuration for pool mode
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :adapter_module, Snakepit.TestAdapters.MockAdapter)
Application.put_env(:snakepit, :pool_config, %{pool_size: 2})

IO.puts("📋 Starting Snakepit with pool enabled...")
{:ok, _apps} = Application.ensure_all_started(:snakepit)

IO.puts("⏳ Waiting for pool to initialize...")
case Snakepit.Pool.await_ready(Snakepit.Pool, 10_000) do
  :ok -> 
    IO.puts("✅ Pool ready!")
    
    # Now run the full demo
    IO.puts("\n🔧 Demo 1: Basic Pool Execution")
    {:ok, result} = Snakepit.execute("ping", %{})
    IO.puts("Basic execution: #{inspect(result)}")
    
    {:ok, result} = Snakepit.execute("echo", %{"message" => "Hello Pool!"})
    IO.puts("Echo execution: #{inspect(result)}")
    
    IO.puts("\n🔗 Demo 2: Session Affinity")
    session_id = "demo_session"
    
    for i <- 1..3 do
      {:ok, result} = Snakepit.execute_in_session(session_id, "ping", %{iteration: i})
      IO.puts("Session call #{i}: #{inspect(result)}")
    end
    
    IO.puts("\n📊 Demo 3: Pool Statistics")
    stats = Snakepit.get_stats()
    IO.puts("Pool statistics: #{stats.requests} requests processed")
    
    IO.puts("\n✨ Demo 4: Session Helpers")
    {:ok, result} = Snakepit.SessionHelpers.execute_in_context(
      "helper_session",
      "echo",
      %{"message" => "Session helper test"}
    )
    IO.puts("Session helper: #{inspect(result)}")
    
    IO.puts("\n🎉 Standalone Pool Demo Complete!")
    IO.puts("✅ All pool functionality working in fresh session!")
    
  {:error, :timeout} ->
    IO.puts("❌ Pool initialization timeout")
    IO.puts("This indicates a configuration or dependency issue")
end