#!/usr/bin/env elixir

# Structured Errors Example
# Demonstrates the new Snakepit.Error struct with detailed error context
# Usage: mix run --no-start examples/structured_errors.exs

Code.require_file("mix_bootstrap.exs", __DIR__)

Snakepit.Examples.Bootstrap.ensure_mix!([
  {:snakepit, path: "."}
])

# Configure Snakepit for gRPC
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
Application.put_env(:snakepit, :pooling_enabled, true)

Application.put_env(:snakepit, :pools, [
  %{
    name: :default,
    worker_profile: :process,
    pool_size: 2,
    adapter_module: Snakepit.Adapters.GRPCPython
  }
])

Application.put_env(:snakepit, :pool_config, %{pool_size: 2})
Application.put_env(:snakepit, :grpc_port, 50051)
Snakepit.Examples.Bootstrap.ensure_grpc_port!()

# Suppress Snakepit internal logs for clean output
Application.put_env(:snakepit, :log_level, :warning)

defmodule StructuredErrorsExample do
  @moduledoc """
  Demonstrates the new structured error types in v0.6.7:
  1. Snakepit.Error struct with detailed context
  2. Error categories for better error handling
  3. Python traceback propagation
  4. gRPC status codes
  5. Pattern matching on structured errors
  """

  def run do
    IO.puts("\n=== Structured Errors Example ===\n")
    IO.puts("Demonstrating the new Snakepit.Error struct with detailed error context.\n")

    # Demo 1: Unknown command error
    demo_unknown_command()

    # Demo 2: Invalid parameters
    demo_invalid_parameters()

    # Demo 3: Pattern matching on error categories
    demo_error_pattern_matching()

    # Demo 4: Error inspection and debugging
    demo_error_inspection()

    IO.puts("\n=== Structured Errors Example Complete ===\n")
    IO.puts("Summary:")
    IO.puts("  - Structured errors provide rich context for debugging")
    IO.puts("  - Error categories enable better error handling patterns")
    IO.puts("  - Python tracebacks help debug Python-side issues")
    IO.puts("  - All error information preserved in Snakepit.Error struct\n")
  end

  defp demo_unknown_command do
    IO.puts("Demo 1: Unknown Command Error")
    IO.puts("  Executing a non-existent command to see structured error...\n")

    case Snakepit.execute("nonexistent_command", %{}) do
      {:ok, result} ->
        IO.puts("  Unexpected success: #{inspect(result)}")

      {:error, %Snakepit.Error{} = error} ->
        IO.puts("  ✓ Received structured error:")
        IO.puts("    Category: #{inspect(error.category)}")
        IO.puts("    Message: #{error.message}")

        if error.details do
          IO.puts("    Details: #{inspect(error.details)}")
        end

        if error.grpc_status do
          IO.puts("    gRPC Status: #{error.grpc_status}")
        end

      {:error, other} ->
        IO.puts("  ⚠️  Received legacy error format: #{inspect(other)}")
    end

    IO.puts("")
  end

  defp demo_invalid_parameters do
    IO.puts("Demo 2: Invalid Parameters")
    IO.puts("  Testing parameter validation...\n")

    # Try to pass invalid data that can't be JSON encoded
    # Note: In Elixir, most data structures are JSON-serializable
    # This demonstrates the error structure if encoding fails

    case Snakepit.execute("add", %{a: 1}) do
      {:ok, result} ->
        IO.puts("  Result: #{inspect(result)}")

      {:error, %Snakepit.Error{} = error} ->
        IO.puts("  ✓ Structured error received:")
        IO.puts("    Category: #{inspect(error.category)}")
        IO.puts("    Message: #{error.message}")

        if error.details do
          IO.puts("    Details:")

          Enum.each(error.details, fn {key, value} ->
            IO.puts("      #{key}: #{inspect(value)}")
          end)
        end

      {:error, other} ->
        IO.puts("  Legacy error: #{inspect(other)}")
    end

    IO.puts("")
  end

  defp demo_error_pattern_matching do
    IO.puts("Demo 3: Pattern Matching on Error Categories")
    IO.puts("  Demonstrating how to handle different error categories...\n")

    commands = [
      {"ping", %{}},
      {"nonexistent_tool", %{}},
      {"add", %{a: 1, b: 2}}
    ]

    for {command, params} <- commands do
      result = Snakepit.execute(command, params)
      handle_result(command, result)
      Process.sleep(50)
    end

    IO.puts("")
  end

  defp handle_result(command, result) do
    case result do
      {:ok, data} ->
        IO.puts("  ✓ #{command}: Success - #{inspect(data)}")

      {:error, %Snakepit.Error{category: :not_found} = error} ->
        IO.puts("  🔍 #{command}: Not found - #{error.message}")
        IO.puts("     → Suggestion: Check if the tool is registered in the adapter")

      {:error, %Snakepit.Error{category: :invalid_parameters} = error} ->
        IO.puts("  📝 #{command}: Invalid parameters - #{error.message}")
        IO.puts("     → Suggestion: Review required parameters for this command")

      {:error, %Snakepit.Error{category: :timeout} = error} ->
        IO.puts("  ⏱️  #{command}: Timeout - #{error.message}")
        IO.puts("     → Suggestion: Increase timeout or check worker health")

      {:error, %Snakepit.Error{category: :execution_failed} = error} ->
        IO.puts("  ❌ #{command}: Execution failed - #{error.message}")

        if error.python_traceback do
          IO.puts("     Python traceback available:")
          IO.puts("     #{String.slice(error.python_traceback, 0, 100)}...")
        end

      {:error, %Snakepit.Error{} = error} ->
        IO.puts("  ⚠️  #{command}: #{error.category} - #{error.message}")

      {:error, other} ->
        IO.puts("  ❌ #{command}: Legacy error - #{inspect(other)}")
    end
  end

  defp demo_error_inspection do
    IO.puts("Demo 4: Error Inspection and Debugging")
    IO.puts("  Showing full error details for debugging...\n")

    case Snakepit.execute("nonexistent_tool_detailed", %{param1: "value1", param2: 42}) do
      {:ok, result} ->
        IO.puts("  Unexpected success: #{inspect(result)}")

      {:error, %Snakepit.Error{} = error} ->
        IO.puts("  Full Error Struct:")
        IO.puts("  " <> String.duplicate("─", 60))

        # Pretty print the error struct
        error
        |> Map.from_struct()
        |> Enum.each(fn {key, value} ->
          case key do
            :python_traceback when is_binary(value) and byte_size(value) > 200 ->
              IO.puts("  #{key}: #{String.slice(value, 0, 200)}... (truncated)")

            :details when is_map(value) ->
              IO.puts("  #{key}:")

              Enum.each(value, fn {k, v} ->
                IO.puts("    #{k}: #{inspect(v)}")
              end)

            _ ->
              IO.puts("  #{key}: #{inspect(value)}")
          end
        end)

        IO.puts("  " <> String.duplicate("─", 60))

        # Demonstrate extracting useful information
        IO.puts("\n  Debugging Information:")
        IO.puts("  → Error occurred in category: #{error.category}")
        IO.puts("  → Human-readable message: #{error.message}")

        if error.grpc_status do
          IO.puts("  → gRPC status code: #{error.grpc_status}")
        end

        if error.details do
          IO.puts("  → Additional context available in details map")
        end

        if error.python_traceback do
          IO.puts("  → Python traceback available for Python-side debugging")
        end

      {:error, other} ->
        IO.puts("  Legacy error format: #{inspect(other)}")
    end

    IO.puts("")
  end
end

# Run the example with proper cleanup
Snakepit.run_as_script(fn ->
  StructuredErrorsExample.run()
end)
