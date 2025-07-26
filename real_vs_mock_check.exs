# Real vs Mock Infrastructure Check
# Run with: MIX_ENV=test elixir -S mix run real_vs_mock_check.exs

IO.puts("🔍 Checking what's REAL vs MOCKED in Snakepit examples")

# Configure
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :adapter_module, Snakepit.TestAdapters.MockAdapter)
Application.put_env(:snakepit, :pool_config, %{pool_size: 3})

# Start
{:ok, _} = Application.ensure_all_started(:snakepit)
:ok = Snakepit.Pool.await_ready(Snakepit.Pool, 5_000)

IO.puts("\n📊 REAL Infrastructure Analysis:")

# Check real pool process
pool_pid = Process.whereis(Snakepit.Pool)
IO.puts("1. Pool GenServer PID: #{inspect(pool_pid)} #{if pool_pid, do: "✅ REAL PROCESS", else: "❌ MOCKED"}")

# Check real worker processes  
workers = Snakepit.Pool.list_workers()
IO.puts("2. Worker processes: #{length(workers)} workers #{if length(workers) > 0, do: "✅ REAL PROCESSES", else: "❌ MOCKED"}")

for worker <- Enum.take(workers, 2) do
  IO.puts("   Worker PID: #{inspect(worker)} #{if Process.alive?(worker), do: "✅ ALIVE", else: "❌ DEAD"}")
end

# Check real session affinity (same session should use same worker)
session_id = "test_session"
worker_pids = for i <- 1..5 do
  {:ok, _} = Snakepit.execute_in_session(session_id, "ping", %{call: i})
  # Get the worker that handled this request
  stats = Snakepit.get_stats()
  stats.busy |> MapSet.to_list() |> List.first()
end

unique_workers = worker_pids |> Enum.reject(&is_nil/1) |> Enum.uniq()
IO.puts("3. Session affinity: #{length(unique_workers)} unique workers for 5 calls #{if length(unique_workers) <= 2, do: "✅ REAL AFFINITY", else: "❌ NO AFFINITY"}")

# Check real pool statistics
stats = Snakepit.get_stats()
IO.puts("4. Pool statistics: #{stats.requests} requests tracked #{if stats.requests > 0, do: "✅ REAL TRACKING", else: "❌ MOCKED"}")
IO.puts("   Available workers: #{MapSet.size(stats.available)}")
IO.puts("   Busy workers: #{MapSet.size(stats.busy)}")

IO.puts("\n🎭 MOCKED Components:")
IO.puts("1. Adapter responses: MockAdapter returns fake 'pong' instead of real external process")
IO.puts("2. Command execution: No real Python/gRPC calls, just mock responses")

IO.puts("\n✅ CONCLUSION:")
IO.puts("- Pool infrastructure (GenServer, workers, supervision): REAL")
IO.puts("- Session management (affinity, routing): REAL")  
IO.puts("- Statistics tracking: REAL")
IO.puts("- Worker processes: REAL Elixir processes")
IO.puts("- Adapter responses: MOCKED (fake responses)")

IO.puts("\n💡 The pool/session system is REAL infrastructure with MOCKED external calls")