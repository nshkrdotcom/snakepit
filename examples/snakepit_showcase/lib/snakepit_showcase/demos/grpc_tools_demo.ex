defmodule SnakepitShowcase.Demos.GrpcToolsDemo do
  @moduledoc """
  Demonstrates the gRPC tools registration issue where the Python adapter
  tries to access response attributes that don't exist on UnaryUnaryCall objects.
  """

  def run do
    IO.puts("🔍 gRPC Tools Registration Issue Demo\n")
    IO.puts("This demo shows the errors that occur when the Python adapter")
    IO.puts("tries to register tools and access Elixir tools.\n")
    
    # Demo 1: Show what happens during tool registration
    demo_tool_registration()
    
    # Demo 2: Show what happens when trying to access Elixir tools
    demo_elixir_tools_access()
    
    # Demo 3: Show that despite the errors, execution still works
    demo_execution_still_works()
    
    :ok
  end

  defp demo_tool_registration do
    IO.puts("1️⃣ Tool Registration Issue")
    IO.puts("━━━━━━━━━━━━━━━━━━━━━━━━━━")
    IO.puts("When the Python adapter starts, it tries to register tools.")
    IO.puts("Watch for these error messages in the logs:\n")
    
    # This will trigger the tool registration
    case Snakepit.execute("adapter_info", %{}) do
      {:ok, result} ->
        IO.puts("✅ Despite registration errors, adapter_info still works!")
        IO.puts("   Adapter: #{result["adapter_name"]}")
        IO.puts("   Version: #{result["version"]}")
        
        IO.puts("\n📋 What happened:")
        IO.puts("   - Python tried to call: response = stub.RegisterTools(request)")
        IO.puts("   - Then tried to access: response.success")
        IO.puts("   - But got: 'UnaryUnaryCall' object has no attribute 'success'")
        IO.puts("   - This suggests the gRPC call returned a Future/Call object")
        IO.puts("   - Instead of the actual response message")
        
      {:error, reason} ->
        IO.puts("❌ Execution failed: #{inspect(reason)}")
    end
  end

  defp demo_elixir_tools_access do
    IO.puts("\n\n2️⃣ Elixir Tools Access Issue")
    IO.puts("━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    IO.puts("When creating SessionContext, Python tries to load Elixir tools.")
    IO.puts("Watch for these error messages in the logs:\n")
    
    # Create a simple tool that tries to use SessionContext
    case Snakepit.execute("echo", %{message: "Testing SessionContext"}) do
      {:ok, result} ->
        IO.puts("✅ Despite Elixir tools errors, echo still works!")
        IO.puts("   Echoed: #{inspect(result["echoed"])}")
        
        IO.puts("\n📋 What happened:")
        IO.puts("   - Python tried to call: response = self.stub.GetExposedElixirTools(request)")
        IO.puts("   - Then tried to access: response.tools")
        IO.puts("   - But got: 'UnaryUnaryCall' object has no attribute 'tools'")
        IO.puts("   - The gRPC stub returned a Call object instead of awaiting the response")
        
      {:error, reason} ->
        IO.puts("❌ Execution failed: #{inspect(reason)}")
    end
  end

  defp demo_execution_still_works do
    IO.puts("\n\n3️⃣ Execution Still Works")
    IO.puts("━━━━━━━━━━━━━━━━━━━━━━━━")
    IO.puts("Despite these errors, the core functionality still works!")
    IO.puts("The errors are caught and logged, but don't break execution.\n")
    
    # Test multiple operations
    operations = [
      {"add", %{a: 10, b: 20}, "Basic math operation"},
      {"process_text", %{text: "Hello World", operation: "upper"}, "Text processing"},
      {"get_stats", %{}, "Statistics gathering"}
    ]
    
    for {op, args, desc} <- operations do
      IO.puts("Testing #{desc}...")
      case Snakepit.execute(op, args) do
        {:ok, result} ->
          IO.puts("   ✅ #{op} succeeded: #{inspect(result)}")
        {:error, _reason} ->
          IO.puts("   ⚠️  #{op} not available (expected for this adapter)")
      end
    end
    
    IO.puts("\n📊 Summary:")
    IO.puts("   - The gRPC infrastructure has async/await issues")
    IO.puts("   - UnaryUnaryCall objects are returned instead of response messages")
    IO.puts("   - This happens in snakepit's Python bridge code, not DSPex")
    IO.puts("   - The errors are non-critical and execution continues")
    IO.puts("   - To fix: The stub calls need to be awaited or invoked properly")
  end
end