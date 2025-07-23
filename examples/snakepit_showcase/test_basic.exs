# Test basic Snakepit commands with ShowcaseAdapter
IO.puts("Testing basic Snakepit commands...\n")

# Start the application
{:ok, _} = Application.ensure_all_started(:snakepit_showcase)

# Test ping command
IO.puts("1. Testing ping command:")
case Snakepit.execute("ping", %{message: "Hello from test!"}) do
  {:ok, result} ->
    IO.puts("   ✅ Success: #{result["message"]}")
  {:error, reason} ->
    IO.puts("   ❌ Failed: #{inspect(reason)}")
end

# Test echo command
IO.puts("\n2. Testing echo command:")
test_data = %{foo: "bar", number: 42}
case Snakepit.execute("echo", test_data) do
  {:ok, result} ->
    IO.puts("   ✅ Success: #{inspect(result["echoed"])}")
  {:error, reason} ->
    IO.puts("   ❌ Failed: #{inspect(reason)}")
end

# Test adapter_info command
IO.puts("\n3. Testing adapter_info command:")
case Snakepit.execute("adapter_info", %{}) do
  {:ok, result} ->
    IO.puts("   ✅ Success:")
    IO.puts("      Adapter: #{result["adapter_name"]}")
    IO.puts("      Version: #{result["version"]}")
  {:error, reason} ->
    IO.puts("   ❌ Failed: #{inspect(reason)}")
end

IO.puts("\nAll tests completed!")