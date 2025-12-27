#!/usr/bin/env elixir

# ML Errors Example
# Demonstrates structured exception handling for ML workloads including
# shape mismatch, device mismatch, OOM errors, and Python error parsing.
#
# Usage: mix run examples/ml_errors.exs

Code.require_file("mix_bootstrap.exs", __DIR__)

Snakepit.Examples.Bootstrap.ensure_mix!([
  {:snakepit, path: "."}
])

defmodule MLErrorsExample do
  @moduledoc """
  Demonstrates Snakepit's structured ML error handling.
  """

  alias Snakepit.Error.{Shape, Device, Parser}

  def run do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("  ML Error Handling")
    IO.puts(String.duplicate("=", 60) <> "\n")

    demo_shape_errors()
    demo_device_errors()
    demo_oom_errors()
    demo_error_parsing()
    demo_pattern_matching()

    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("  ML Error Handling Demo Complete!")
    IO.puts(String.duplicate("=", 60) <> "\n")
  end

  defp demo_shape_errors do
    IO.puts("1. Shape Mismatch Errors")
    IO.puts(String.duplicate("-", 40))

    # Create shape mismatch error
    error = Shape.shape_mismatch([3, 224, 224], [3, 256, 256], "conv2d")

    IO.puts("   Shape Mismatch Error:")
    IO.puts("   - Expected: #{inspect(error.expected)}")
    IO.puts("   - Got: #{inspect(error.got)}")
    IO.puts("   - Operation: #{error.operation}")
    IO.puts("   - Dimension: #{error.dimension || "N/A"}")
    IO.puts("\n   Message: #{Exception.message(error)}")

    # Create dimension mismatch error
    dim_error = Shape.dimension_mismatch(2, 224, 256, "conv2d")

    IO.puts("\n   Dimension Mismatch Error:")
    IO.puts("   - Dimension: #{dim_error.dimension}")
    IO.puts("   - Expected: #{dim_error.expected_dim}")
    IO.puts("   - Got: #{dim_error.got_dim}")
    IO.puts("   - Operation: #{dim_error.operation}")
    IO.puts("\n   Message: #{Exception.message(dim_error)}")

    IO.puts("")
  end

  defp demo_device_errors do
    IO.puts("2. Device Mismatch Errors")
    IO.puts(String.duplicate("-", 40))

    # Create device mismatch error
    error = Device.device_mismatch(:cpu, {:cuda, 0}, "matmul")

    IO.puts("   Device Mismatch Error:")
    IO.puts("   - Expected: #{inspect(error.expected)}")
    IO.puts("   - Got: #{inspect(error.got)}")
    IO.puts("   - Operation: #{error.operation}")
    IO.puts("\n   Message: #{Exception.message(error)}")

    # Create device unavailable error
    unavailable = Device.device_unavailable({:cuda, 2}, "forward_pass")

    IO.puts("\n   Device Unavailable Error:")
    IO.puts("   - Device: #{inspect(unavailable.got)}")
    IO.puts("   - Operation: #{unavailable.operation}")
    IO.puts("\n   Message: #{Exception.message(unavailable)}")

    IO.puts("")
  end

  defp demo_oom_errors do
    IO.puts("3. Out of Memory Errors")
    IO.puts(String.duplicate("-", 40))

    # Create OOM error with memory sizes
    # Requested 2GB, only 512MB available
    error =
      Device.out_of_memory(
        {:cuda, 0},
        2 * 1024 * 1024 * 1024,
        512 * 1024 * 1024
      )

    IO.puts("   Out of Memory Error:")
    IO.puts("   - Device: #{inspect(error.device)}")
    IO.puts("   - Requested: #{format_bytes(error.requested_bytes)}")
    IO.puts("   - Available: #{format_bytes(error.available_bytes)}")
    IO.puts("\n   Message: #{Exception.message(error)}")

    IO.puts("\n   Recovery Suggestions:")

    for suggestion <- error.suggestions do
      IO.puts("   - #{suggestion}")
    end

    IO.puts("")
  end

  defp demo_error_parsing do
    IO.puts("4. Python Error Parsing")
    IO.puts(String.duplicate("-", 40))

    # Parse shape mismatch from Python error
    IO.puts("   a) Parsing shape mismatch error:")

    shape_data = %{
      "type" => "RuntimeError",
      "message" => "shape mismatch: expected [3, 224, 224], got [3, 256, 256]"
    }

    {:ok, shape_error} = Parser.parse(shape_data)
    IO.puts("      Input: #{shape_data["message"]}")
    IO.puts("      Parsed type: #{shape_error.__struct__ |> Module.split() |> List.last()}")
    IO.puts("      Expected shape: #{inspect(shape_error.expected)}")
    IO.puts("      Got shape: #{inspect(shape_error.got)}")

    # Parse OOM from Python error
    IO.puts("\n   b) Parsing CUDA OOM error:")

    oom_data = %{
      "type" => "RuntimeError",
      "message" => "CUDA out of memory. Tried to allocate 2.00 GiB"
    }

    {:ok, oom_error} = Parser.parse(oom_data)
    IO.puts("      Input: #{oom_data["message"]}")
    IO.puts("      Parsed type: #{oom_error.__struct__ |> Module.split() |> List.last()}")
    IO.puts("      Device: #{inspect(oom_error.device)}")
    IO.puts("      Requested: #{format_bytes(oom_error.requested_bytes)}")

    # Parse device mismatch from Python error
    IO.puts("\n   c) Parsing device mismatch error:")

    device_data = %{
      "type" => "RuntimeError",
      "message" => "Expected all tensors to be on the same device, but found cuda:0 and cpu!"
    }

    {:ok, device_error} = Parser.parse(device_data)
    IO.puts("      Input: #{device_data["message"]}")
    IO.puts("      Parsed type: #{device_error.__struct__ |> Module.split() |> List.last()}")
    IO.puts("      Expected: #{inspect(device_error.expected)}")
    IO.puts("      Got: #{inspect(device_error.got)}")

    # Parse standard Python exception
    IO.puts("\n   d) Parsing standard Python exception:")

    value_data = %{
      "type" => "ValueError",
      "message" => "Invalid input dimension",
      "traceback" => "File \"model.py\", line 42, in forward\n  ..."
    }

    {:ok, value_error} = Parser.parse(value_data)
    IO.puts("      Input type: #{value_data["type"]}")
    IO.puts("      Parsed type: #{value_error.__struct__ |> Module.split() |> List.last()}")
    IO.puts("      Python type: #{value_error.python_type}")
    IO.puts("      Message: #{value_error.message}")

    # Parse from gRPC error
    IO.puts("\n   e) Parsing from gRPC error response:")

    grpc_error = %{
      status: :internal,
      message: "ValueError: expected positive value"
    }

    {:ok, parsed} = Parser.from_grpc_error(grpc_error)
    IO.puts("      gRPC message: #{grpc_error.message}")
    IO.puts("      Parsed type: #{parsed.__struct__ |> Module.split() |> List.last()}")

    # Extract shape helper
    IO.puts("\n   f) Shape extraction helper:")

    for shape_str <- ["[3, 224, 224]", "(10, 20, 30)", "[batch, 512]"] do
      shape = Parser.extract_shape(shape_str)
      IO.puts("      \"#{shape_str}\" -> #{inspect(shape)}")
    end

    IO.puts("")
  end

  defp demo_pattern_matching do
    IO.puts("5. Pattern Matching on Errors")
    IO.puts(String.duplicate("-", 40))

    # Simulate various error scenarios
    errors = [
      Shape.shape_mismatch([3, 224, 224], [3, 256, 256], "conv2d"),
      Device.device_mismatch(:cpu, {:cuda, 0}, "forward"),
      Device.out_of_memory({:cuda, 0}, 2_147_483_648, 536_870_912),
      Shape.dimension_mismatch(0, 32, 64, "batch_norm")
    ]

    IO.puts("   Handling different ML error types:\n")

    for error <- errors do
      handle_ml_error(error)
    end

    IO.puts("")
  end

  defp handle_ml_error(%Snakepit.Error.ShapeMismatch{dimension: nil} = error) do
    IO.puts("   [ShapeMismatch] Operation: #{error.operation}")
    IO.puts("      Fix: Reshape input from #{inspect(error.got)} to #{inspect(error.expected)}")
  end

  defp handle_ml_error(%Snakepit.Error.ShapeMismatch{dimension: dim} = error) when dim != nil do
    IO.puts("   [DimensionMismatch] Operation: #{error.operation}")
    IO.puts("      Fix: Dimension #{dim} should be #{error.expected_dim}, got #{error.got_dim}")
  end

  defp handle_ml_error(%Snakepit.Error.DeviceMismatch{} = error) do
    IO.puts("   [DeviceMismatch] Operation: #{error.operation}")
    IO.puts("      Fix: Move tensor to #{inspect(error.expected)} device")
  end

  defp handle_ml_error(%Snakepit.Error.OutOfMemory{} = error) do
    IO.puts("   [OutOfMemory] Device: #{inspect(error.device)}")

    IO.puts(
      "      Needed: #{format_bytes(error.requested_bytes)}, Available: #{format_bytes(error.available_bytes)}"
    )

    IO.puts("      Suggestions:")

    for suggestion <- Enum.take(error.suggestions, 2) do
      IO.puts("        - #{suggestion}")
    end
  end

  defp handle_ml_error(error) do
    IO.puts("   [Unknown] #{Exception.message(error)}")
  end

  defp format_bytes(bytes) when bytes >= 1_073_741_824 do
    "#{Float.round(bytes / 1_073_741_824, 2)} GB"
  end

  defp format_bytes(bytes) when bytes >= 1_048_576 do
    "#{Float.round(bytes / 1_048_576, 2)} MB"
  end

  defp format_bytes(bytes) do
    "#{bytes} bytes"
  end
end

# Run the example
MLErrorsExample.run()
