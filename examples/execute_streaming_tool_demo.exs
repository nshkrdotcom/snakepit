#!/usr/bin/env elixir

# Demo: Streaming Tool Execution via Pool
#
# This example demonstrates Snakepit's streaming tool execution capability
# using `Snakepit.execute_stream/3`, which routes through the Pool to a
# Python worker that yields chunks incrementally.
#
# Note: This uses the Pool → GRPCWorker → Python path, which is the
# recommended way for Elixir applications to consume streaming tools.
#
# For external gRPC clients calling into Snakepit's BridgeServer,
# see guides/streaming.md for the ExecuteStreamingTool RPC documentation.
#
# Prerequisites:
#   - Python adapter with streaming tool registered
#   - Snakepit pool running with ShowcaseAdapter or similar
#
# Run:
#   mix run examples/execute_streaming_tool_demo.exs

Code.require_file("mix_bootstrap.exs", __DIR__)

Snakepit.Examples.Bootstrap.ensure_mix!([
  {:snakepit, path: "."}
])

# Enable pooling for this demo
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{pool_size: 2})
Application.put_env(:snakepit, :grpc_port, 50051)
Application.put_env(:snakepit, :grpc_host, "localhost")
Application.put_env(:snakepit, :log_level, :error)
Snakepit.Examples.Bootstrap.ensure_grpc_port!()

defmodule StreamingToolDemo do
  @moduledoc """
  Demonstrates streaming tool execution via `Snakepit.execute_stream/3`.

  ## Architecture Overview

  There are two streaming paths in Snakepit:

  1. **Pool Streaming** (this demo): Elixir app → Pool → GRPCWorker → Python
     - Uses `Snakepit.execute_stream/3`
     - Best for Elixir applications consuming streaming tools

  2. **BridgeServer Streaming** (v0.8.5+): External gRPC client → BridgeServer → Worker
     - Uses `ExecuteStreamingTool` RPC
     - For external clients calling Snakepit as a gRPC service
     - Requires tools with `supports_streaming: true` metadata

  This demo shows the Pool streaming path (#1).
  """

  require Logger

  def run do
    IO.puts("=== Streaming Tool Demo ===\n")
    IO.puts("This demo uses Snakepit.execute_stream/3 (Pool → Worker streaming)\n")
    IO.puts("Pool ready. Running demos...\n")
    demo_progress_streaming()
    demo_data_streaming()
    IO.puts("\n=== Demo Complete ===")
  end

  defp demo_progress_streaming do
    IO.puts("1. Progress Streaming")
    IO.puts("   Streaming progress updates...\n")

    result =
      Snakepit.execute_stream(
        "stream_progress",
        %{steps: 5},
        fn chunk ->
          case chunk do
            %{"step" => step, "total" => total} ->
              progress = Float.round(step / total * 100, 1)
              IO.puts("   Step #{step}/#{total}: #{progress}%")

            %{"status" => "complete"} ->
              IO.puts("   Status: Complete!")

            other ->
              IO.puts("   Chunk: #{inspect(other)}")
          end
        end
      )

    case result do
      :ok -> IO.puts("   Success!\n")
      {:error, e} -> IO.puts("   Error: #{inspect(e)}\n")
    end
  end

  defp demo_data_streaming do
    IO.puts("2. Echo Streaming (fallback demo)")
    IO.puts("   Using echo tool to demonstrate chunk handling...\n")

    # Use the simpler echo tool if stream_data isn't available
    result =
      Snakepit.execute(
        "echo",
        %{message: "Hello from streaming demo!"}
      )

    case result do
      {:ok, response} ->
        IO.puts("   Response: #{inspect(response)}")
        IO.puts("   Success!\n")

      {:error, e} ->
        IO.puts("   Error: #{inspect(e)}\n")
    end
  end
end

# Run the demo using the bootstrap wrapper which handles pool startup/teardown
Snakepit.Examples.Bootstrap.run_example(fn ->
  StreamingToolDemo.run()
end)
