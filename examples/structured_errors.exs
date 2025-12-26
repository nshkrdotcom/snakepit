#!/usr/bin/env elixir

# Structured Errors Example
# Demonstrates structured Python exception translation in Snakepit 0.7.4
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
  Demonstrates structured Python exception translation in v0.7.4:
  1. Python exceptions mapped to Snakepit.Error.* structs
  2. Fallback to Snakepit.Error.PythonException for unmapped types
  3. Callsite metadata and tracebacks preserved
  4. Pattern matching on error structs
  """

  def run do
    IO.puts("\n=== Structured Errors Example ===\n")
    IO.puts("Demonstrating structured Python exception translation in v0.7.4.\n")

    # Demo 1: Unknown tool error
    demo_unknown_tool()

    # Demo 2: ValueError translation
    demo_value_error()

    # Demo 3: Pattern matching on error structs
    demo_error_pattern_matching()

    # Demo 4: Error inspection and debugging
    demo_error_inspection()

    IO.puts("\n=== Structured Errors Example Complete ===\n")
    IO.puts("Summary:")
    IO.puts("  - Python exceptions map to specific Snakepit.Error.* structs")
    IO.puts("  - Unmapped exceptions fall back to Snakepit.Error.PythonException")
    IO.puts("  - Callsite context + traceback metadata stay available")
    IO.puts("  - System/runtime errors still surface as Snakepit.Error\n")
  end

  defp demo_unknown_tool do
    IO.puts("Demo 1: Unknown Tool Error")
    IO.puts("  Executing a non-existent tool to see structured error...\n")

    case Snakepit.execute("nonexistent_command", %{}) do
      {:ok, result} ->
        IO.puts("  Unexpected success: #{inspect(result)}")

      {:error, %Snakepit.Error.AttributeError{} = error} ->
        IO.puts("  ✓ Received mapped Python error (AttributeError):")
        print_python_exception(error)

      {:error, %Snakepit.Error.PythonException{} = error} ->
        IO.puts("  ✓ Received Python error:")
        print_python_exception(error)

      {:error, %Snakepit.Error{} = error} ->
        IO.puts("  ✓ Received Snakepit error:")
        IO.puts("    Category: #{inspect(error.category)}")
        IO.puts("    Message: #{error.message}")

      {:error, other} ->
        IO.puts("  ⚠️  Received legacy error format: #{inspect(other)}")
    end

    IO.puts("")
  end

  defp demo_value_error do
    IO.puts("Demo 2: ValueError Translation")
    IO.puts("  Executing error_demo with error_type=value...\n")

    case Snakepit.execute("error_demo", %{error_type: "value"}) do
      {:ok, result} ->
        IO.puts("  Unexpected success: #{inspect(result)}")

      {:error, %Snakepit.Error.ValueError{} = error} ->
        IO.puts("  ✓ Received mapped Python error (ValueError):")
        print_python_exception(error)

      {:error, %Snakepit.Error.PythonException{} = error} ->
        IO.puts("  ✓ Received Python error:")
        print_python_exception(error)

      {:error, other} ->
        IO.puts("  Legacy error: #{inspect(other)}")
    end

    IO.puts("")
  end

  defp demo_error_pattern_matching do
    IO.puts("Demo 3: Pattern Matching on Error Structs")
    IO.puts("  Demonstrating how to handle different Python errors...\n")

    commands = [
      {"error_demo", %{error_type: "value"}},
      {"error_demo", %{error_type: "runtime"}},
      {"error_demo", %{error_type: "generic"}}
    ]

    for {command, params} <- commands do
      result = Snakepit.execute(command, params)
      handle_result(command, result)
    end

    IO.puts("")
  end

  defp handle_result(command, result) do
    case result do
      {:ok, data} ->
        IO.puts("  ✓ #{command}: Success - #{inspect(data)}")

      {:error, %Snakepit.Error.ValueError{} = error} ->
        IO.puts("  ❌ #{command}: ValueError - #{error.message}")

      {:error, %Snakepit.Error.RuntimeError{} = error} ->
        IO.puts("  ❌ #{command}: RuntimeError - #{error.message}")

      {:error, %Snakepit.Error.PythonException{} = error} ->
        IO.puts("  ❌ #{command}: #{error.python_type} - #{error.message}")

      {:error, %Snakepit.Error{} = error} ->
        IO.puts("  ⚠️  #{command}: #{error.category} - #{error.message}")

      {:error, other} ->
        IO.puts("  ❌ #{command}: Legacy error - #{inspect(other)}")
    end
  end

  defp demo_error_inspection do
    IO.puts("Demo 4: Error Inspection and Debugging")
    IO.puts("  Showing full error details for debugging...\n")

    case Snakepit.execute("error_demo", %{error_type: "generic"}) do
      {:ok, result} ->
        IO.puts("  Unexpected success: #{inspect(result)}")

      {:error, %Snakepit.Error.PythonException{} = error} ->
        IO.puts("  Full Error Struct:")
        IO.puts("  " <> String.duplicate("─", 60))

        # Pretty print the error struct
        error
        |> Map.from_struct()
        |> Enum.each(fn {key, value} ->
          cond do
            key == :python_traceback and is_binary(value) and byte_size(value) > 200 ->
              IO.puts("  #{key}: #{String.slice(value, 0, 200)}... (truncated)")

            key == :context and is_map(value) ->
              IO.puts("  #{key}:")

              Enum.each(value, fn {k, v} ->
                IO.puts("    #{k}: #{inspect(v)}")
              end)

            true ->
              IO.puts("  #{key}: #{inspect(value)}")
          end
        end)

        IO.puts("  " <> String.duplicate("─", 60))

        # Demonstrate extracting useful information
        IO.puts("\n  Debugging Information:")
        IO.puts("  → Python type: #{error.python_type}")
        IO.puts("  → Message: #{error.message}")

        if error.context do
          IO.puts("  → Callsite context available (tool/session metadata)")
        end

        if error.python_traceback do
          IO.puts("  → Python traceback available for Python-side debugging")
        end

      {:error, %Snakepit.Error{} = error} ->
        IO.puts("  Snakepit error: #{error.message}")

      {:error, other} ->
        IO.puts("  Legacy error format: #{inspect(other)}")
    end

    IO.puts("")
  end

  defp print_python_exception(error) do
    python_type = error.python_type || error.__struct__ |> Module.split() |> List.last()

    IO.puts("    Python Type: #{python_type}")
    IO.puts("    Message: #{error.message}")

    if is_map(error.context) and map_size(error.context) > 0 do
      IO.puts("    Context: #{inspect(error.context)}")
    end

    if is_binary(error.python_traceback) do
      IO.puts("    Traceback: #{String.slice(error.python_traceback, 0, 120)}...")
    end
  end
end

# Run the example with proper cleanup
Snakepit.Examples.Bootstrap.run_example(fn ->
  StructuredErrorsExample.run()
end)
