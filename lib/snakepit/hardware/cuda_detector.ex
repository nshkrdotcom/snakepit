defmodule Snakepit.Hardware.CUDADetector do
  @moduledoc """
  CUDA GPU hardware detection.

  Detects NVIDIA CUDA-capable GPUs using nvidia-smi when available.
  """

  @type cuda_device :: %{
          id: non_neg_integer(),
          name: String.t(),
          memory_total_mb: non_neg_integer(),
          memory_free_mb: non_neg_integer(),
          compute_capability: String.t() | nil
        }

  @type cuda_info :: %{
          version: String.t(),
          driver_version: String.t(),
          devices: [cuda_device()],
          cudnn_version: String.t() | nil
        }

  @doc """
  Detects CUDA GPU information.

  Returns nil if CUDA is not available, or a map with:
  - `:version` - CUDA runtime version (e.g., "12.1")
  - `:driver_version` - NVIDIA driver version
  - `:devices` - List of CUDA device maps
  - `:cudnn_version` - cuDNN version if available, nil otherwise
  """
  @spec detect() :: cuda_info() | nil
  def detect do
    with {:ok, driver_version} <- detect_driver_version(),
         {:ok, cuda_version} <- detect_cuda_version(),
         {:ok, devices} <- detect_devices() do
      %{
        version: cuda_version,
        driver_version: driver_version,
        devices: devices,
        cudnn_version: detect_cudnn_version()
      }
    else
      _ -> nil
    end
  end

  @spec detect_driver_version() :: {:ok, String.t()} | :error
  defp detect_driver_version do
    case run_nvidia_smi(["--query-gpu=driver_version", "--format=csv,noheader,nounits"]) do
      {:ok, output} ->
        version =
          output
          |> String.split("\n")
          |> List.first()
          |> String.trim()

        if version != "" do
          {:ok, version}
        else
          :error
        end

      :error ->
        :error
    end
  end

  @spec detect_cuda_version() :: {:ok, String.t()} | :error
  defp detect_cuda_version do
    # Try nvidia-smi for CUDA version
    case run_nvidia_smi(["--query-gpu=cuda_version", "--format=csv,noheader,nounits"]) do
      {:ok, output} ->
        version =
          output
          |> String.split("\n")
          |> List.first()
          |> String.trim()

        if version != "" and version != "[N/A]" do
          {:ok, version}
        else
          detect_cuda_version_fallback()
        end

      :error ->
        detect_cuda_version_fallback()
    end
  end

  defp detect_cuda_version_fallback do
    # Try nvcc --version as fallback
    case System.cmd("nvcc", ["--version"], stderr_to_stdout: true) do
      {output, 0} ->
        case Regex.run(~r/release (\d+\.\d+)/, output) do
          [_, version] -> {:ok, version}
          _ -> :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  @spec detect_devices() :: {:ok, [cuda_device()]} | :error
  defp detect_devices do
    query = [
      "--query-gpu=index,name,memory.total,memory.free,compute_cap",
      "--format=csv,noheader,nounits"
    ]

    case run_nvidia_smi(query) do
      {:ok, output} ->
        devices =
          output
          |> String.split("\n")
          |> Enum.filter(&(&1 != ""))
          |> Enum.map(&parse_device_line/1)
          |> Enum.filter(&(&1 != nil))

        {:ok, devices}

      :error ->
        :error
    end
  end

  defp parse_device_line(line) do
    case String.split(line, ", ") do
      [id_str, name, mem_total_str, mem_free_str, compute_cap] ->
        %{
          id: safe_parse_integer(id_str, 0),
          name: String.trim(name),
          memory_total_mb: safe_parse_integer(mem_total_str, 0),
          memory_free_mb: safe_parse_integer(mem_free_str, 0),
          compute_capability: normalize_compute_cap(compute_cap)
        }

      [id_str, name, mem_total_str, mem_free_str] ->
        %{
          id: safe_parse_integer(id_str, 0),
          name: String.trim(name),
          memory_total_mb: safe_parse_integer(mem_total_str, 0),
          memory_free_mb: safe_parse_integer(mem_free_str, 0),
          compute_capability: nil
        }

      _ ->
        nil
    end
  end

  defp safe_parse_integer(str, default) do
    str
    |> String.trim()
    |> Integer.parse()
    |> case do
      {n, _} -> n
      :error -> default
    end
  end

  defp normalize_compute_cap(cap) do
    cap = String.trim(cap)

    if cap in ["[N/A]", "N/A", ""] do
      nil
    else
      cap
    end
  end

  @spec detect_cudnn_version() :: String.t() | nil
  defp detect_cudnn_version do
    # cuDNN version is not easily detectable without Python
    # Return nil for now, can be populated via Python probe
    nil
  end

  @spec run_nvidia_smi([String.t()]) :: {:ok, String.t()} | :error
  defp run_nvidia_smi(args) do
    case System.cmd("nvidia-smi", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      _ -> :error
    end
  rescue
    _ -> :error
  end
end
