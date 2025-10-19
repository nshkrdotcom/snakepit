#!/usr/bin/env elixir

# Session Management with gRPC Example
# Demonstrates session affinity and stateful operation routing

# Configure Snakepit for gRPC
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_size, 4)

Application.put_env(:snakepit, :pools, [
  %{
    name: :default,
    worker_profile: :process,
    pool_size: 4,
    adapter_module: Snakepit.Adapters.GRPCPython
  }
])

Application.put_env(:snakepit, :pool_config, %{pool_size: 4})
Application.put_env(:snakepit, :grpc_port, 50051)

Code.require_file("mix_bootstrap.exs", __DIR__)

Snakepit.Examples.Bootstrap.ensure_mix!([
  {:snakepit, path: "."},
  {:grpc, "~> 0.10.2"},
  {:protobuf, "~> 0.14.1"}
])

IO.inspect(Application.get_env(:snakepit, :pool_size),
  label: "example pool_size env",
  limit: :infinity
)

defmodule SessionExample do
  def run do
    IO.puts("\n=== Session Management Example ===\n")

    # Create unique session IDs
    sessions = for i <- 1..3, do: "demo_session_#{i}_#{System.unique_integer([:positive])}"
    IO.puts("Created #{length(sessions)} sessions")

    # 1. Session affinity - same session should prefer same worker
    IO.puts("\n1. Testing session affinity:")

    Enum.each(sessions, fn session_id ->
      # Make multiple calls with the same session_id
      worker_ids =
        for _ <- 1..5 do
          {:ok, result} = Snakepit.execute_in_session(session_id, "ping", %{})
          result["worker_id"] || "unknown"
        end

      unique_workers = Enum.uniq(worker_ids)
      IO.puts("  #{session_id}: Used #{length(unique_workers)} worker(s) for 5 calls")
      IO.puts("    Workers: #{inspect(unique_workers)}")

      if length(unique_workers) == 1 do
        IO.puts("    ✅ Perfect affinity - all calls used same worker")
      else
        IO.puts("    ⚠️  Affinity not perfect - multiple workers used")
      end
    end)

    # 2. Concurrent session operations
    IO.puts("\n2. Concurrent operations across sessions:")

    tasks =
      for session_id <- sessions do
        Task.async(fn ->
          results =
            for i <- 1..3 do
              {:ok, result} =
                Snakepit.execute_in_session(session_id, "add", %{
                  a: i,
                  b: i * 2
                })

              result
            end

          {session_id, results}
        end)
      end

    results = Task.await_many(tasks, 10_000)

    Enum.each(results, fn {session_id, session_results} ->
      IO.puts("  #{session_id}: Completed #{length(session_results)} operations")
    end)

    # 3. Session isolation - operations in different sessions use different workers
    IO.puts("\n3. Testing session isolation:")

    session_to_worker =
      Enum.map(sessions, fn session_id ->
        {:ok, result} = Snakepit.execute_in_session(session_id, "ping", %{})
        {session_id, result["worker_id"] || "unknown"}
      end)

    Enum.each(session_to_worker, fn {session_id, worker_id} ->
      IO.puts("  #{session_id} → Worker: #{worker_id}")
    end)

    unique_workers_used = session_to_worker |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    IO.puts("\n  Total unique workers used: #{length(unique_workers_used)}")

    if length(unique_workers_used) == length(sessions) do
      IO.puts("  ✅ Perfect isolation - each session has its own worker")
    else
      IO.puts(
        "  ℹ️  Some sessions share workers (expected with #{length(sessions)} sessions on 4 workers)"
      )
    end

    # 4. Session statistics
    IO.puts("\n4. Session statistics:")

    _session_info =
      Enum.map(session_to_worker, fn {session_id, worker_id} ->
        case Snakepit.Bridge.SessionStore.get_session(session_id) do
          {:ok, session} ->
            IO.puts("  #{session_id}:")
            IO.puts("    Worker: #{worker_id}")
            IO.puts("    Created: #{Map.get(session, :created_at, "unknown")}")
            IO.puts("    Last accessed: #{Map.get(session, :last_accessed_at, "unknown")}")

          {:error, :not_found} ->
            IO.puts("  #{session_id}: Not found in SessionStore")
        end
      end)

    IO.puts("\n✅ Session management example complete")
    IO.puts("Sessions will auto-expire after TTL (default: 3600s)")
  end
end

# Run the example with proper cleanup
Snakepit.run_as_script(fn ->
  SessionExample.run()
end)
