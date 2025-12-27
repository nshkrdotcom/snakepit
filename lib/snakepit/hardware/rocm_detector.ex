defmodule Snakepit.Hardware.ROCmDetector do
  @moduledoc """
  AMD ROCm GPU hardware detection.

  Detects AMD GPUs with ROCm support using rocm-smi when available.
  """

  @type rocm_device :: %{
          id: non_neg_integer(),
          name: String.t(),
          memory_total_mb: non_neg_integer(),
          memory_free_mb: non_neg_integer()
        }

  @type rocm_info :: %{
          version: String.t(),
          devices: [rocm_device()]
        }

  @doc """
  Detects ROCm GPU information.

  Returns nil if ROCm is not available, or a map with:
  - `:version` - ROCm version
  - `:devices` - List of ROCm device maps
  """
  @spec detect() :: rocm_info() | nil
  def detect do
    with {:ok, version} <- detect_version(),
         {:ok, devices} <- detect_devices() do
      %{
        version: version,
        devices: devices
      }
    else
      _ -> nil
    end
  end

  @spec detect_version() :: {:ok, String.t()} | :error
  defp detect_version do
    # Try rocm-smi for version
    case System.cmd("rocm-smi", ["--showversion"], stderr_to_stdout: true) do
      {output, 0} ->
        case Regex.run(~r/ROCm version:\s*(\d+\.\d+(?:\.\d+)?)/, output) do
          [_, version] -> {:ok, version}
          _ -> try_rocm_version_file()
        end

      _ ->
        try_rocm_version_file()
    end
  rescue
    _ -> :error
  end

  defp try_rocm_version_file do
    case File.read("/opt/rocm/.info/version") do
      {:ok, content} ->
        version = String.trim(content)
        if version != "", do: {:ok, version}, else: :error

      _ ->
        :error
    end
  end

  @spec detect_devices() :: {:ok, [rocm_device()]} | :error
  defp detect_devices do
    case System.cmd("rocm-smi", ["--showid", "--showmeminfo", "vram"], stderr_to_stdout: true) do
      {output, 0} ->
        devices = parse_rocm_devices(output)
        {:ok, devices}

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp parse_rocm_devices(output) do
    # Parse rocm-smi output format
    # This is simplified - actual parsing depends on rocm-smi version
    lines = String.split(output, "\n")

    lines
    |> Enum.chunk_every(4)
    |> Enum.with_index()
    |> Enum.map(fn {chunk, idx} ->
      parse_device_chunk(chunk, idx)
    end)
    |> Enum.filter(&(&1 != nil))
  end

  defp parse_device_chunk(chunk, idx) do
    name =
      Enum.find_value(chunk, "AMD GPU", fn line ->
        if String.contains?(line, "GPU") do
          line
          |> String.replace(~r/GPU\[\d+\]/, "")
          |> String.replace(":", "")
          |> String.trim()
        end
      end)

    %{
      id: idx,
      name: if(name == "", do: "AMD GPU #{idx}", else: name),
      memory_total_mb: 0,
      memory_free_mb: 0
    }
  end
end
