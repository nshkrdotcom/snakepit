defmodule SnakepitShowcase.Demos.BasicDemo do
  @moduledoc """
  Demonstrates basic Snakepit operations including simple command execution,
  error handling, and health checks.
  """

  def run do
    IO.puts("🔧 Basic Operations Demo\n")
    
    # Demo 1: Health check
    demo_health_check()
    
    # Demo 2: Simple echo
    demo_echo()
    
    # Demo 3: Error handling
    demo_error_handling()
    
    # Demo 4: Custom adapter
    demo_custom_adapter()
    
    :ok
  end

  defp demo_health_check do
    IO.puts("1️⃣ Health Check")
    
    case Snakepit.execute("ping", %{message: "Hello from Elixir!"}) do
      {:ok, result} ->
        IO.puts("   ✅ Ping successful!")
        IO.puts("   Response: #{result["message"]}")
        IO.puts("   Timestamp: #{result["timestamp"]}")
      {:error, reason} ->
        IO.puts("   ❌ Ping failed: #{inspect(reason)}")
    end
  end

  defp demo_echo do
    IO.puts("\n2️⃣ Echo Command")
    
    test_data = %{
      "string" => "Hello, World!",
      "number" => 42,
      "float" => 3.14159,
      "boolean" => true,
      "list" => [1, 2, 3, 4, 5],
      "nested" => %{
        "key1" => "value1",
        "key2" => [1, 2, 3]
      }
    }
    
    {:ok, result} = Snakepit.execute("echo", test_data)
    
    IO.puts("   Sent: #{inspect(test_data, pretty: true)}")
    IO.puts("   Received: #{inspect(result["echoed"], pretty: true)}")
    IO.puts("   ✅ Data echoed successfully!")
  end

  defp demo_error_handling do
    IO.puts("\n3️⃣ Error Handling")
    
    # Test different error types
    error_types = ["value", "runtime", "generic"]
    
    Enum.each(error_types, fn error_type ->
      IO.puts("   Testing #{error_type} error:")
      
      case Snakepit.execute("error_demo", %{error_type: error_type}) do
        {:ok, _} ->
          IO.puts("     ❌ Expected error but got success!")
        {:error, reason} ->
          IO.puts("     ✅ Caught error: #{inspect(reason)}")
      end
    end)
  end

  defp demo_custom_adapter do
    IO.puts("\n4️⃣ Custom Adapter Usage")
    
    # The adapter is configured in the pool config
    {:ok, result} = Snakepit.execute("adapter_info", %{})
    
    IO.puts("   Adapter: #{result["adapter_name"]}")
    IO.puts("   Version: #{result["version"]}")
    IO.puts("   Capabilities: #{inspect(result["capabilities"])}")
  end
end