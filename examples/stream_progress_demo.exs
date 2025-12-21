#!/usr/bin/env elixir

Code.require_file("mix_bootstrap.exs", __DIR__)

Snakepit.Examples.Bootstrap.ensure_mix!([
  {:snakepit, path: "."}
])

Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :grpc_port, 50051)
Application.put_env(:snakepit, :grpc_host, "localhost")
Application.put_env(:snakepit, :log_level, :warning)
Snakepit.Examples.Bootstrap.ensure_grpc_port!()

Snakepit.run_as_script(fn ->
  IO.puts("Starting stream_progress demo (5 steps)...")

  callback = fn chunk ->
    step = Map.get(chunk, "step") || chunk["step"]
    total = Map.get(chunk, "total") || chunk["total"]
    message = Map.get(chunk, "message") || inspect(chunk)
    elapsed = Map.get(chunk, "elapsed_ms")
    progress = Map.get(chunk, "progress")

    IO.puts("[step #{step}/#{total}] #{message} (progress: #{progress}%, elapsed: #{elapsed} ms)")

    if chunk["is_final"] do
      IO.puts("Stream complete!\n")
    end
  end

  params = %{"steps" => 5, "delay_ms" => 750}

  case Snakepit.execute_stream("stream_progress", params, callback, timeout: 30_000) do
    :ok -> :ok
    {:error, reason} -> IO.puts("Streaming failed: #{inspect(reason)}")
  end
end)
