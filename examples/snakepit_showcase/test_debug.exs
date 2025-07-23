# Debug test to see actual response
{:ok, _} = Application.ensure_all_started(:snakepit_showcase)
Process.sleep(2000)

IO.puts("Testing ping command with full response...")
result = Snakepit.execute("ping", %{message: "Hello!"})
IO.puts("Full result: #{inspect(result, pretty: true)}")

# Test echo too
IO.puts("\nTesting echo command...")
result2 = Snakepit.execute("echo", %{test: "data"})
IO.puts("Echo result: #{inspect(result2, pretty: true)}")