# Simple test with timeout handling
{:ok, _} = Application.ensure_all_started(:snakepit_showcase)

# Give servers time to start
Process.sleep(2000)

IO.puts("Testing ping command...")
case Snakepit.execute("ping", %{message: "Hello!"}) do
  {:ok, result} -> 
    IO.puts("Success: #{inspect(result)}")
  {:error, reason} -> 
    IO.puts("Error: #{inspect(reason)}")
end