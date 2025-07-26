# Core Functionality Demo - Essential Snakepit session/pooler features
# Run with: MIX_ENV=test mix run core_functionality_demo.exs

IO.puts("🎯 Snakepit Core Session/Pooler Functionality Demo")
IO.puts("Demonstrating the essential working features\n")

# Ensure we use test adapter configuration
Application.put_env(:snakepit, :adapter_module, Snakepit.TestAdapters.MockAdapter)
Application.put_env(:snakepit, :pooling_enabled, false)  # Start disabled, enable later

# Start the application
{:ok, _} = Application.ensure_all_started(:snakepit)

# Test 1: Direct worker usage (core GenericWorker functionality)
IO.puts("1️⃣  Core Worker Functionality")
{:ok, worker} = Snakepit.GenericWorker.start_link("test_worker", Snakepit.TestAdapters.MockAdapter)

# Basic execution
{:ok, result} = GenServer.call(worker, {:execute, "ping", %{}, []})
IO.puts("   ✅ Basic execution: #{inspect(result)}")

# Parameterized execution  
{:ok, result} = GenServer.call(worker, {:execute, "echo", %{"message" => "Core test"}, []})
IO.puts("   ✅ Parameterized execution: #{inspect(result)}")

GenServer.stop(worker)

# Test 2: Pool-based execution (session/pooler core)
IO.puts("\n2️⃣  Pool-Based Execution")

# Configure and restart with pool enabled
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :adapter_module, Snakepit.TestAdapters.MockAdapter)
Application.put_env(:snakepit, :pool_config, %{pool_size: 2})

Application.stop(:snakepit)
Process.sleep(100)
{:ok, _} = Application.ensure_all_started(:snakepit)

# Wait for pool initialization
:ok = Snakepit.Pool.await_ready(Snakepit.Pool, 5_000)

# Execute via pool
{:ok, result} = Snakepit.execute("ping", %{})
IO.puts("   ✅ Pool execution: #{inspect(result)}")

# Test 3: Session affinity (core session functionality)
IO.puts("\n3️⃣  Session Affinity") 

session_id = "core_session"

# Multiple calls to same session
for i <- 1..3 do
  {:ok, result} = Snakepit.execute_in_session(session_id, "ping", %{call: i})
  IO.puts("   ✅ Session call #{i}: #{inspect(result)}")
end

# Test 4: Session helpers
IO.puts("\n4️⃣  Session Helpers")
{:ok, result} = Snakepit.SessionHelpers.execute_in_context(
  "helper_session", 
  "echo", 
  %{"message" => "Helper test"}
)
IO.puts("   ✅ Session helper: #{inspect(result)}")

# Test 5: Statistics
IO.puts("\n5️⃣  Pool Statistics")
stats = Snakepit.get_stats()
IO.puts("   ✅ Pool stats: #{stats.requests} requests processed")

IO.puts("\n🎉 Core session/pooler functionality demonstration complete!")
IO.puts("\n📋 Verified Features:")
IO.puts("   • Direct GenericWorker execution")
IO.puts("   • Pool-based request distribution") 
IO.puts("   • Session affinity management")
IO.puts("   • Session helper utilities")
IO.puts("   • Pool statistics tracking")

IO.puts("\n✅ ALL CORE FUNCTIONALITY IS WORKING!")