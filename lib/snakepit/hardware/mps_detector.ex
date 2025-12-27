defmodule Snakepit.Hardware.MPSDetector do
  @moduledoc """
  Apple Metal Performance Shaders (MPS) hardware detection.

  Detects Apple Silicon GPU availability on macOS.
  """

  @type mps_info :: %{
          available: boolean(),
          device_name: String.t(),
          memory_total_mb: non_neg_integer()
        }

  @doc """
  Detects MPS (Apple Metal) availability.

  Returns nil on non-macOS platforms, or a map with:
  - `:available` - true if MPS is available
  - `:device_name` - Name of the Metal device
  - `:memory_total_mb` - GPU memory (shared memory on Apple Silicon)
  """
  @spec detect() :: mps_info() | nil
  def detect do
    case :os.type() do
      {:unix, :darwin} -> detect_darwin()
      _ -> nil
    end
  end

  defp detect_darwin do
    # Check if we're on Apple Silicon
    case detect_apple_silicon() do
      {:ok, device_name} ->
        memory_mb = detect_unified_memory()

        %{
          available: true,
          device_name: device_name,
          memory_total_mb: memory_mb
        }

      :error ->
        # Check for Intel Mac with AMD GPU
        case detect_discrete_gpu() do
          {:ok, device_name, memory_mb} ->
            %{
              available: true,
              device_name: device_name,
              memory_total_mb: memory_mb
            }

          :error ->
            nil
        end
    end
  end

  defp detect_apple_silicon do
    # Check CPU brand for Apple Silicon
    case System.cmd("sysctl", ["-n", "machdep.cpu.brand_string"], stderr_to_stdout: true) do
      {output, 0} ->
        brand = String.trim(output)

        if String.contains?(brand, "Apple") do
          # Get specific chip name
          case System.cmd("sysctl", ["-n", "hw.model"], stderr_to_stdout: true) do
            {model, 0} ->
              model = String.trim(model)
              chip = extract_chip_name(brand, model)
              {:ok, "#{chip} GPU"}

            _ ->
              {:ok, "Apple GPU"}
          end
        else
          :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp extract_chip_name(brand, _model) do
    cond do
      String.contains?(brand, "M1") -> "Apple M1"
      String.contains?(brand, "M2") -> "Apple M2"
      String.contains?(brand, "M3") -> "Apple M3"
      String.contains?(brand, "M4") -> "Apple M4"
      true -> "Apple Silicon"
    end
  end

  defp detect_unified_memory do
    # On Apple Silicon, GPU uses unified memory
    case System.cmd("sysctl", ["-n", "hw.memsize"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.trim()
        |> String.to_integer()
        |> div(1024 * 1024)

      _ ->
        0
    end
  rescue
    _ -> 0
  end

  defp detect_discrete_gpu do
    # For Intel Macs with discrete AMD GPU
    case System.cmd("system_profiler", ["SPDisplaysDataType"], stderr_to_stdout: true) do
      {output, 0} ->
        parse_discrete_gpu(output)

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp parse_discrete_gpu(output) do
    # Look for AMD Radeon or similar
    lines = String.split(output, "\n")

    gpu_name =
      Enum.find_value(lines, fn line ->
        cond do
          String.contains?(line, "AMD Radeon") ->
            line |> String.trim() |> String.replace(":", "")

          String.contains?(line, "Metal Family") ->
            # Has Metal support
            nil

          true ->
            nil
        end
      end)

    case gpu_name do
      nil ->
        :error

      name ->
        # Try to find VRAM
        vram =
          Enum.find_value(lines, 0, fn line ->
            if String.contains?(line, "VRAM") do
              case Regex.run(~r/(\d+)\s*MB/, line) do
                [_, mb] -> String.to_integer(mb)
                _ -> nil
              end
            end
          end)

        {:ok, name, vram}
    end
  end
end
