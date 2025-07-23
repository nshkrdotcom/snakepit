# Test script to verify orphan cleanup
Application.ensure_all_started(:snakepit)

# Start just one worker
{:ok, worker} = Snakepit.GRPCWorker.start_link(
  adapter: Snakepit.Adapters.GRPCPython,
  id: "test_worker_1"
)

IO.puts("Worker started: #{inspect(worker)}")

# Sleep to let it initialize
Process.sleep(2000)

# Now exit without cleanup (simulating a crash)
IO.puts("Exiting without cleanup...")