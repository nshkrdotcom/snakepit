defmodule Snakepit.Hardware.CPUDetector do
  @moduledoc """
  CPU hardware detection.

  Detects CPU model, cores, threads, memory, and CPU features (SSE, AVX, etc.).
  """

  @type cpu_info :: %{
          cores: pos_integer(),
          threads: pos_integer(),
          model: String.t(),
          features: [atom()],
          memory_total_mb: non_neg_integer()
        }

  @doc """
  Detects CPU hardware information.

  Returns a map with:
  - `:cores` - Number of physical CPU cores
  - `:threads` - Number of logical threads (cores * hyperthreading)
  - `:model` - CPU model name string
  - `:features` - List of detected CPU feature atoms (e.g., `:avx`, `:sse4_2`)
  - `:memory_total_mb` - Total system memory in MB
  """
  @spec detect() :: cpu_info()
  def detect do
    %{
      cores: detect_cores(),
      threads: detect_threads(),
      model: detect_model(),
      features: detect_features(),
      memory_total_mb: detect_memory_mb()
    }
  end

  @spec detect_cores() :: pos_integer()
  defp detect_cores do
    # Try to get physical cores (System.schedulers always returns >= 1)
    n = System.schedulers()
    max(1, div(n, 2))
  end

  @spec detect_threads() :: pos_integer()
  defp detect_threads do
    # System.schedulers_online always returns >= 1
    System.schedulers_online()
  end

  @spec detect_model() :: String.t()
  defp detect_model do
    case :os.type() do
      {:unix, :linux} -> detect_model_linux()
      {:unix, :darwin} -> detect_model_darwin()
      {:win32, _} -> detect_model_windows()
      _ -> "Unknown"
    end
  end

  defp detect_model_linux do
    try do
      case File.read("/proc/cpuinfo") do
        {:ok, content} ->
          content
          |> String.split("\n")
          |> Enum.find(fn line -> String.starts_with?(line, "model name") end)
          |> case do
            nil -> "Unknown"
            line -> line |> String.split(":") |> List.last() |> String.trim()
          end

        _ ->
          "Unknown"
      end
    rescue
      _ -> "Unknown"
    end
  end

  defp detect_model_darwin do
    try do
      case System.cmd("sysctl", ["-n", "machdep.cpu.brand_string"], stderr_to_stdout: true) do
        {output, 0} -> String.trim(output)
        _ -> "Apple Silicon"
      end
    rescue
      _ -> "Unknown"
    end
  end

  defp detect_model_windows do
    try do
      case System.cmd("wmic", ["cpu", "get", "name", "/value"], stderr_to_stdout: true) do
        {output, 0} ->
          output
          |> String.split("=")
          |> List.last()
          |> String.trim()

        _ ->
          "Unknown"
      end
    rescue
      _ -> "Unknown"
    end
  end

  @spec detect_features() :: [atom()]
  defp detect_features do
    case :os.type() do
      {:unix, :linux} -> detect_features_linux()
      {:unix, :darwin} -> detect_features_darwin()
      _ -> []
    end
  end

  defp detect_features_linux do
    try do
      case File.read("/proc/cpuinfo") do
        {:ok, content} ->
          content
          |> String.split("\n")
          |> Enum.find(fn line -> String.starts_with?(line, "flags") end)
          |> case do
            nil ->
              []

            line ->
              line
              |> String.split(":")
              |> List.last()
              |> String.split()
              |> Enum.map(&normalize_feature/1)
              |> Enum.filter(&(&1 != nil))
          end

        _ ->
          []
      end
    rescue
      _ -> []
    end
  end

  defp detect_features_darwin do
    try do
      features = []

      features =
        case System.cmd("sysctl", ["-n", "hw.optional.avx1_0"], stderr_to_stdout: true) do
          {"1\n", 0} -> [:avx | features]
          _ -> features
        end

      features =
        case System.cmd("sysctl", ["-n", "hw.optional.avx2_0"], stderr_to_stdout: true) do
          {"1\n", 0} -> [:avx2 | features]
          _ -> features
        end

      features =
        case System.cmd("sysctl", ["-n", "hw.optional.sse4_1"], stderr_to_stdout: true) do
          {"1\n", 0} -> [:sse4_1 | features]
          _ -> features
        end

      features =
        case System.cmd("sysctl", ["-n", "hw.optional.sse4_2"], stderr_to_stdout: true) do
          {"1\n", 0} -> [:sse4_2 | features]
          _ -> features
        end

      # ARM/Apple Silicon features
      features =
        case System.cmd("sysctl", ["-n", "hw.optional.neon"], stderr_to_stdout: true) do
          {"1\n", 0} -> [:neon | features]
          _ -> features
        end

      features
    rescue
      _ -> []
    end
  end

  @known_features %{
    "avx" => :avx,
    "avx2" => :avx2,
    "avx512f" => :avx512,
    "sse4_1" => :sse4_1,
    "sse4_2" => :sse4_2,
    "sse3" => :sse3,
    "ssse3" => :ssse3,
    "fma" => :fma,
    "f16c" => :f16c,
    "aes" => :aes,
    "pclmulqdq" => :pclmul,
    "neon" => :neon,
    "asimd" => :asimd
  }

  defp normalize_feature(flag) do
    Map.get(@known_features, String.downcase(flag))
  end

  @spec detect_memory_mb() :: non_neg_integer()
  defp detect_memory_mb do
    # Use :erlang.memory() total as approximation
    # This gives the Erlang VM's view but is portable
    try do
      case :os.type() do
        {:unix, :linux} ->
          detect_memory_linux()

        {:unix, :darwin} ->
          detect_memory_darwin()

        _ ->
          # Fallback to erlang memory
          div(:erlang.memory(:total), 1024 * 1024)
      end
    rescue
      _ -> 0
    end
  end

  defp detect_memory_linux do
    case File.read("/proc/meminfo") do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.find(fn line -> String.starts_with?(line, "MemTotal") end)
        |> case do
          nil ->
            0

          line ->
            line
            |> String.replace(~r/[^\d]/, "")
            |> String.trim()
            |> String.to_integer()
            |> div(1024)
        end

      _ ->
        0
    end
  end

  defp detect_memory_darwin do
    case System.cmd("sysctl", ["-n", "hw.memsize"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.trim()
        |> String.to_integer()
        |> div(1024 * 1024)

      _ ->
        0
    end
  end
end
