#!/usr/bin/env elixir

# Configure Snakepit for non-streaming demo
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{pool_size: 48})
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GenericPythonV2)

Mix.install([
  {:snakepit, path: "."}
])

Logger.configure(level: :info)

IO.puts("🚀 Non-Streaming Demo")
IO.puts("Shows basic request/response patterns")

{:ok, _} = Application.ensure_all_started(:snakepit)

try do
  # Test basic commands
  {:ok, result} = Snakepit.execute("ping", %{})
  IO.puts("✅ Ping: #{result["status"]}")
  
  {:ok, result} = Snakepit.execute("echo", %{"text" => "Hello!"})
  IO.puts("✅ Echo: #{result["echoed"]["text"]}")
  
  {:ok, result} = Snakepit.execute("compute", %{"operation" => "add", "a" => 10, "b" => 20})
  IO.puts("✅ Math: 10 + 20 = #{result["result"]}")
  
  IO.puts("\n🎉 Basic commands work!")
  IO.puts("💡 These same commands work via gRPC when configured")
  
rescue
  e ->
    IO.puts("❌ Error: #{inspect(e)}")
end

# *** CRITICAL: Explicit graceful shutdown (always run, regardless of success/error) ***
IO.puts("\n[Demo Script] Initiating graceful application shutdown...")
Application.stop(:snakepit)

IO.puts("[Demo Script] Shutdown complete. Exiting.")