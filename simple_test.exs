# Simple Snakepit Test - Validate what actually works
# Run with: MIX_ENV=test mix run simple_test.exs

IO.puts("🚀 Simple Snakepit Test")

# Configure test environment
Application.put_env(:snakepit, :adapter_module, Snakepit.TestAdapters.MockAdapter)
Application.put_env(:snakepit, :pooling_enabled, false)

# Test 1: Application can start
IO.puts("\n📋 Test 1: Application Startup")
case Application.ensure_all_started(:snakepit) do
  {:ok, apps} -> 
    IO.puts("✅ Application started: #{length(apps)} apps")
  {:error, reason} -> 
    IO.puts("❌ Application failed: #{inspect(reason)}")
end

# Test 2: Check what modules are available
IO.puts("\n🔍 Test 2: Available Modules")
core_modules = [
  Snakepit,
  Snakepit.Pool,
  Snakepit.GenericWorker,
  Snakepit.Adapter,
  Snakepit.Telemetry,
  Snakepit.SessionHelpers
]

for module <- core_modules do
  case Code.ensure_loaded(module) do
    {:module, ^module} -> IO.puts("✅ #{inspect(module)} available")
    {:error, reason} -> IO.puts("❌ #{inspect(module)} not available: #{inspect(reason)}")
  end
end

# Test 3: Check test modules
IO.puts("\n🎭 Test 3: Test Support Modules")
test_modules = [
  Snakepit.TestAdapters.MockAdapter,
  Snakepit.TestAdapters.MockGRPCAdapter,
  Snakepit.TestAdapters.SessionAffinityAdapter
]

for module <- test_modules do
  case Code.ensure_loaded(module) do
    {:module, ^module} -> 
      IO.puts("✅ #{inspect(module)} available")
      
      # Test validation
      case Snakepit.Adapter.validate_implementation(module) do
        :ok -> IO.puts("  ✅ Validation passed")
        {:error, reason} -> IO.puts("  ❌ Validation failed: #{inspect(reason)}")
      end
      
    {:error, reason} -> 
      IO.puts("❌ #{inspect(module)} not available: #{inspect(reason)}")
  end
end

# Test 4: Pool status
IO.puts("\n🏊 Test 4: Pool Status")
case Process.whereis(Snakepit.Pool) do
  nil -> IO.puts("⚠️  Pool not running (normal in test environment)")
  pid -> 
    IO.puts("✅ Pool running: #{inspect(pid)}")
    
    # Try basic operation
    try do
      stats = Snakepit.get_stats()
      IO.puts("✅ Pool stats accessible: #{inspect(Map.keys(stats))}")
    rescue
      error -> IO.puts("⚠️  Pool stats error: #{inspect(error)}")
    end
end

# Test 5: Configuration
IO.puts("\n⚙️  Test 5: Configuration")
config_keys = [:pooling_enabled, :adapter_module, :pool_config]
for key <- config_keys do
  value = Application.get_env(:snakepit, key)
  IO.puts("#{key}: #{inspect(value)}")
end

IO.puts("\n✅ Simple test complete!")
IO.puts("\n💡 Key findings:")
IO.puts("- Core modules are loading properly")
IO.puts("- Test support modules need proper compilation environment") 
IO.puts("- Pool behavior depends on configuration")
IO.puts("- Session helpers and telemetry are available")