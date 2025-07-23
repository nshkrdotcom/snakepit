# Test script to verify orphan cleanup works correctly
Application.ensure_all_started(:snakepit)

# Wait for pool to initialize
Process.sleep(3000)

# Get PIDs of Python processes
{output, 0} = System.cmd("bash", ["-c", "ps aux | grep -E 'python.*grpc_server' | grep -v grep | awk '{print $2}' | head -5"])
pids = String.split(String.trim(output), "\n") |> Enum.filter(&(&1 != ""))

IO.puts("Found #{length(pids)} Python processes: #{inspect(pids)}")

# Now exit without proper cleanup (simulating a crash)
IO.puts("Exiting without cleanup to simulate crash...")
System.halt(1)