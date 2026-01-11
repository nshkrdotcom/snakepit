#!/usr/bin/env elixir

# Session Affinity Modes Example
# Demonstrates hint vs strict queue vs strict fail-fast behavior

Code.require_file("mix_bootstrap.exs", __DIR__)

Snakepit.Examples.Bootstrap.ensure_mix!([
  {:snakepit, path: "."},
  {:grpc, "~> 0.10.2"},
  {:protobuf, "~> 0.14.1"}
])

Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
Application.put_env(:snakepit, :pooling_enabled, true)

Application.put_env(:snakepit, :pools, [
  %{
    name: :hint_pool,
    worker_profile: :process,
    pool_size: 2,
    adapter_module: Snakepit.Adapters.GRPCPython,
    affinity: :hint
  },
  %{
    name: :strict_queue_pool,
    worker_profile: :process,
    pool_size: 2,
    adapter_module: Snakepit.Adapters.GRPCPython,
    affinity: :strict_queue
  },
  %{
    name: :strict_fail_fast_pool,
    worker_profile: :process,
    pool_size: 2,
    adapter_module: Snakepit.Adapters.GRPCPython,
    affinity: :strict_fail_fast
  }
])

Application.put_env(:snakepit, :pool_config, %{pool_size: 2})
Application.put_env(:snakepit, :grpc_port, 50051)
Snakepit.Examples.Bootstrap.ensure_grpc_port!()

IO.puts("\n=== Session Affinity Modes Example ===\n")

defmodule AffinityModesExample do
  def run do
    :ok = Snakepit.Pool.await_ready(Snakepit.Pool, 30_000)

    run_mode(:hint_pool, "hint")
    run_mode(:strict_queue_pool, "strict_queue")
    run_mode(:strict_fail_fast_pool, "strict_fail_fast")
  end

  defp run_mode(pool_name, label) do
    session_id = "affinity_#{label}_#{System.unique_integer([:positive])}"

    IO.puts("\n--- Mode: #{label} (pool: #{pool_name}) ---")

    long_task =
      Task.async(fn ->
        Snakepit.execute_in_session(
          session_id,
          "sleep_task",
          %{duration_ms: 400, task_number: 1},
          pool_name: pool_name
        )
      end)

    preferred_worker = wait_for_affinity(session_id, 20)
    IO.puts("Preferred worker: #{preferred_worker || "unknown"}")

    {result, duration_ms} =
      timed(fn ->
        Snakepit.execute_in_session(session_id, "ping", %{}, pool_name: pool_name)
      end)

    final_worker = current_worker(session_id)

    IO.puts("Second call duration: #{duration_ms}ms")
    IO.puts("Final worker: #{final_worker || "unknown"}")
    IO.puts("Result: #{inspect(result)}")

    case {label, result} do
      {"hint", {:ok, _}} ->
        IO.puts("Hint mode can fall back; worker changed? #{preferred_worker != final_worker}")

      {"strict_queue", {:ok, _}} ->
        IO.puts("Strict queue waits for preferred worker: #{preferred_worker == final_worker}")

      {"strict_fail_fast", {:error, :worker_busy}} ->
        IO.puts("Strict fail-fast returns :worker_busy while preferred is busy")

      _ ->
        IO.puts("Unexpected result for #{label}: #{inspect(result)}")
    end

    _ = Task.await(long_task, 5_000)
  end

  defp wait_for_affinity(session_id, attempts) when attempts > 0 do
    case Snakepit.Bridge.SessionStore.get_session(session_id) do
      {:ok, %{last_worker_id: worker_id}} when is_binary(worker_id) ->
        worker_id

      _ ->
        Process.sleep(25)
        wait_for_affinity(session_id, attempts - 1)
    end
  end

  defp wait_for_affinity(_session_id, _attempts), do: nil

  defp current_worker(session_id) do
    case Snakepit.Bridge.SessionStore.get_session(session_id) do
      {:ok, %{last_worker_id: worker_id}} -> worker_id
      _ -> nil
    end
  end

  defp timed(fun) when is_function(fun, 0) do
    start_ms = System.monotonic_time(:millisecond)
    result = fun.()
    duration_ms = System.monotonic_time(:millisecond) - start_ms
    {result, duration_ms}
  end
end

Snakepit.Examples.Bootstrap.run_example(fn ->
  AffinityModesExample.run()
end)
