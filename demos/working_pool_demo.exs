# Working Pool Demo - Demonstrates Snakepit with actual pool
# Run with: MIX_ENV=test elixir -S mix run working_pool_demo.exs

IO.puts("🏊‍♂️ Working Pool Demo")

# The key is to set config BEFORE starting the application
# The application reads config at startup time
IO.puts("📋 Configuring pool settings...")
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :adapter_module, Snakepit.TestAdapters.MockAdapter)
Application.put_env(:snakepit, :pool_config, %{pool_size: 2})

IO.puts("📋 Starting application with pool enabled...")
case Application.ensure_all_started(:snakepit) do
  {:ok, _} -> IO.puts("✅ Application started")
  {:error, reason} -> 
    IO.puts("❌ Application failed: #{inspect(reason)}")
    System.halt(1)
end

# Check if pool started
IO.puts("⏳ Checking pool status...")
case Process.whereis(Snakepit.Pool) do
  nil -> 
    IO.puts("❌ Pool process not found")
    IO.puts("This usually means the application was already running with pooling disabled.")
    IO.puts("To fix: restart Elixir session or use the script with a fresh start.")
    
    IO.puts("💡 The pool requires a fresh Elixir session to start properly.")
    IO.puts("💡 Run this demo with: MIX_ENV=test elixir -S mix run working_pool_demo.exs")
    IO.puts("💡 Or see fresh_pool_demo.exs for a working version.")
    System.halt(1)
    
  pid ->
    IO.puts("✅ Pool process found: #{inspect(pid)}")
    case Snakepit.Pool.await_ready(Snakepit.Pool, 5_000) do
      :ok -> IO.puts("✅ Pool ready!")
      {:error, :timeout} -> 
        IO.puts("❌ Pool timeout")
        System.halt(1)
    end
end

# Demo 1: Basic execution
IO.puts("\n🔧 Demo 1: Basic Pool Execution")
{:ok, result} = Snakepit.execute("ping", %{})
IO.puts("Ping result: #{inspect(result)}")

{:ok, result} = Snakepit.execute("echo", %{"message" => "Hello Pool!"})
IO.puts("Echo result: #{inspect(result)}")

# Demo 2: Session affinity
IO.puts("\n🔗 Demo 2: Session Affinity")
session_id = "demo_session_#{System.unique_integer()}"

for i <- 1..3 do
  {:ok, result} = Snakepit.execute_in_session(session_id, "ping", %{iteration: i})
  IO.puts("Session #{session_id} iteration #{i}: #{inspect(result)}")
end

# Demo 3: Pool statistics
IO.puts("\n📊 Demo 3: Pool Statistics")
stats = Snakepit.get_stats()
IO.puts("Pool statistics:")
IO.puts("- Requests: #{stats.requests}")
IO.puts("- Workers: #{length(stats.workers)}")
IO.puts("- Available: #{MapSet.size(stats.available)}")

# Demo 4: Session helpers
IO.puts("\n✨ Demo 4: Enhanced Session Helpers")
{:ok, result} = Snakepit.SessionHelpers.execute_in_context(
  session_id,
  "echo", 
  %{"message" => "Enhanced execution"}
)
IO.puts("Enhanced session result: #{inspect(result)}")

# Demo 5: Error handling
IO.puts("\n⚠️  Demo 5: Error Handling")
{:error, error} = Snakepit.execute("error", %{})
IO.puts("Error handling: #{inspect(error)}")

# Pool still works after error
{:ok, result} = Snakepit.execute("ping", %{})
IO.puts("Pool recovery: #{inspect(result)}")

IO.puts("\n🎉 Working Pool Demo Complete!")
IO.puts("\n📈 Final Statistics:")
final_stats = Snakepit.get_stats()
IO.puts("Total requests processed: #{final_stats.requests}")
IO.puts("Active workers: #{length(final_stats.workers)}")

IO.puts("\n✅ Snakepit core session/pooler functionality is WORKING!")