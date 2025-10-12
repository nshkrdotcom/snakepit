defmodule Snakepit.Compatibility do
  @moduledoc """
  Library compatibility checking for thread-safe execution.

  This module maintains a compatibility matrix of popular Python libraries
  and their thread safety characteristics. It helps users understand which
  libraries work well with the `:thread` worker profile vs `:process` profile.

  ## Usage

      # Check if a library is thread-safe
      case Snakepit.Compatibility.check("numpy", :thread) do
        :ok -> "Safe to use"
        {:warning, msg} -> "Warning: " <> msg
        {:unknown, msg} -> "Unknown: " <> msg
      end

      # Get full library info
      {:ok, info} = Snakepit.Compatibility.get_library_info("torch")

  ## Compatibility Status

  - **Thread-safe**: Library can be used safely with `:thread` profile
  - **Not thread-safe**: Library should only be used with `:process` profile
  - **Conditional**: Thread-safe with specific configuration
  - **Unknown**: Thread safety not verified

  ## Sources

  Compatibility information is gathered from:
  - Official library documentation
  - https://py-free-threading.github.io/tracking/
  - https://hugovk.github.io/free-threaded-wheels/
  - Community testing and reports
  """

  @type thread_safe :: boolean()
  @type profile :: :process | :thread
  @type check_result :: :ok | {:warning, String.t()} | {:unknown, String.t()}

  # Compatibility matrix
  # Updated based on official Python 3.13+ free-threading documentation
  @library_compatibility %{
    # Scientific Computing - Generally thread-safe with GIL released
    "numpy" => %{
      thread_safe: true,
      notes: "Releases GIL during computation. Thread-safe since 1.20.0",
      min_version: "1.20.0",
      recommendation: "Safe for :thread profile",
      gil_behavior: "released"
    },
    "scipy" => %{
      thread_safe: true,
      notes: "Releases GIL for numerical operations",
      min_version: "1.7.0",
      recommendation: "Safe for :thread profile",
      gil_behavior: "released"
    },
    # Deep Learning - Most are thread-safe
    "torch" => %{
      thread_safe: true,
      notes: "Thread-safe with proper initialization. Use torch.set_num_threads()",
      min_version: "2.0.0",
      recommendation: "Safe for :thread profile with configuration",
      gil_behavior: "released",
      workaround: "Set torch.set_num_threads() per worker"
    },
    "pytorch" => %{
      thread_safe: true,
      notes: "Alias for torch",
      min_version: "2.0.0",
      recommendation: "Safe for :thread profile with configuration",
      gil_behavior: "released"
    },
    "tensorflow" => %{
      thread_safe: true,
      notes: "Thread-safe. Configure thread pools appropriately",
      min_version: "2.10.0",
      recommendation: "Safe for :thread profile with configuration",
      gil_behavior: "released",
      workaround: "Use tf.config.threading API"
    },
    # Data Processing - Varies
    "pandas" => %{
      thread_safe: false,
      notes: "Not thread-safe as of v2.0. DataFrame operations may race",
      min_version: nil,
      recommendation: "Use :process profile",
      gil_behavior: "held",
      workaround: "Use with explicit locking or :process profile"
    },
    "polars" => %{
      thread_safe: true,
      notes: "Designed for parallel execution",
      min_version: "0.16.0",
      recommendation: "Excellent for :thread profile",
      gil_behavior: "released"
    },
    # Visualization - Generally not thread-safe
    "matplotlib" => %{
      thread_safe: false,
      notes: "Not thread-safe. Use thread-local figures or explicit locking",
      min_version: nil,
      recommendation: "Use :process profile or thread-local figures",
      gil_behavior: "held",
      workaround: "Use thread-local storage: threading.local()"
    },
    "plotly" => %{
      thread_safe: true,
      notes: "Thread-safe for figure creation",
      min_version: "5.0.0",
      recommendation: "Safe for :thread profile",
      gil_behavior: "released"
    },
    # Database - Mixed
    "sqlite3" => %{
      thread_safe: false,
      notes: "Not thread-safe by default. Use check_same_thread=False with caution",
      min_version: nil,
      recommendation: "Use :process profile or connection pooling",
      gil_behavior: "held",
      workaround: "Use connection per thread or :process profile"
    },
    "psycopg2" => %{
      thread_safe: true,
      notes: "Thread-safe at connection level (not cursor level)",
      min_version: "2.9.0",
      recommendation: "Safe for :thread profile with connection per thread",
      gil_behavior: "released"
    },
    # Web - Generally safe
    "requests" => %{
      thread_safe: true,
      notes: "Thread-safe for separate sessions",
      min_version: "2.25.0",
      recommendation: "Safe for :thread profile",
      gil_behavior: "released"
    },
    "httpx" => %{
      thread_safe: true,
      notes: "Async-first, thread-safe",
      min_version: "0.23.0",
      recommendation: "Excellent for :thread profile",
      gil_behavior: "released"
    },
    # ML Libraries
    "scikit-learn" => %{
      thread_safe: true,
      notes: "Thread-safe with n_jobs parameter control",
      min_version: "1.0.0",
      recommendation: "Safe for :thread profile",
      gil_behavior: "released",
      workaround: "Set n_jobs=1 per estimator to avoid over-subscription"
    },
    "xgboost" => %{
      thread_safe: true,
      notes: "Thread-safe with nthread parameter",
      min_version: "1.6.0",
      recommendation: "Safe for :thread profile with configuration",
      gil_behavior: "released",
      workaround: "Set nthread parameter appropriately"
    },
    "lightgbm" => %{
      thread_safe: true,
      notes: "Thread-safe with num_threads parameter",
      min_version: "3.3.0",
      recommendation: "Safe for :thread profile with configuration",
      gil_behavior: "released",
      workaround: "Set num_threads parameter"
    },
    # NLP
    "transformers" => %{
      thread_safe: true,
      notes: "Thread-safe for inference with separate model instances",
      min_version: "4.20.0",
      recommendation: "Safe for :thread profile",
      gil_behavior: "released"
    },
    "spacy" => %{
      thread_safe: true,
      notes: "Thread-safe with separate nlp instances per thread",
      min_version: "3.4.0",
      recommendation: "Safe for :thread profile with thread-local models",
      gil_behavior: "released",
      workaround: "Use threading.local() for nlp instances"
    }
  }

  @doc """
  Check if a library is compatible with a given worker profile.

  Returns:
  - `:ok` - Library is safe to use
  - `{:warning, message}` - Library may have issues
  - `{:unknown, message}` - Compatibility unknown

  ## Examples

      iex> Snakepit.Compatibility.check("numpy", :thread)
      :ok

      iex> Snakepit.Compatibility.check("pandas", :thread)
      {:warning, "Not thread-safe as of v2.0..."}

      iex> Snakepit.Compatibility.check("unknown_lib", :thread)
      {:unknown, "Compatibility unknown for unknown_lib"}
  """
  @spec check(library :: String.t(), profile) :: check_result()
  def check(library, profile) do
    case Map.get(@library_compatibility, library) do
      nil ->
        {:unknown, "Compatibility unknown for #{library}. Check library documentation."}

      info ->
        check_compatibility(library, info, profile)
    end
  end

  @doc """
  Get detailed information about a library's compatibility.

  ## Examples

      iex> Snakepit.Compatibility.get_library_info("torch")
      {:ok, %{
        thread_safe: true,
        notes: "Thread-safe with proper initialization...",
        recommendation: "Safe for :thread profile with configuration"
      }}
  """
  @spec get_library_info(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_library_info(library) do
    case Map.get(@library_compatibility, library) do
      nil -> {:error, :not_found}
      info -> {:ok, info}
    end
  end

  @doc """
  List all libraries in the compatibility matrix.

  Returns a map grouped by thread safety status.

  ## Examples

      iex> Snakepit.Compatibility.list_all()
      %{
        thread_safe: ["numpy", "torch", ...],
        not_thread_safe: ["pandas", "matplotlib", ...],
        conditional: ["scikit-learn", ...]
      }
  """
  @spec list_all() :: map()
  def list_all do
    Enum.group_by(@library_compatibility, fn {_lib, info} ->
      cond do
        info.thread_safe and Map.has_key?(info, :workaround) -> :conditional
        info.thread_safe -> :thread_safe
        true -> :not_thread_safe
      end
    end)
    |> Map.new(fn {category, libs} ->
      {category, Enum.map(libs, fn {lib, _info} -> lib end) |> Enum.sort()}
    end)
  end

  @doc """
  Generate a compatibility report for a list of libraries.

  Useful for validating an adapter's dependencies before deployment.

  ## Examples

      iex> Snakepit.Compatibility.generate_report(["numpy", "pandas"], :thread)
      %{
        compatible: ["numpy"],
        warnings: [{"pandas", "Not thread-safe..."}],
        unknown: []
      }
  """
  @spec generate_report([String.t()], profile) :: map()
  def generate_report(libraries, profile) do
    results =
      Enum.map(libraries, fn lib ->
        {lib, check(lib, profile)}
      end)

    %{
      compatible: for({lib, :ok} <- results, do: lib),
      warnings: for({lib, {:warning, msg}} <- results, do: {lib, msg}),
      unknown: for({lib, {:unknown, msg}} <- results, do: {lib, msg})
    }
  end

  @doc """
  Check if a specific Python version is recommended for a library.

  Some libraries require specific Python versions for free-threading support.

  ## Examples

      iex> Snakepit.Compatibility.check_python_version("numpy", {3, 13, 0})
      :ok

      iex> Snakepit.Compatibility.check_python_version("pandas", {3, 13, 0})
      {:warning, "Library may not be optimized for Python 3.13 free-threading"}
  """
  @spec check_python_version(String.t(), {integer(), integer(), integer()}) :: check_result()
  def check_python_version(library, python_version) do
    case get_library_info(library) do
      {:ok, info} ->
        {py_major, py_minor, _py_patch} = python_version

        cond do
          info.thread_safe and py_major == 3 and py_minor >= 13 ->
            :ok

          not info.thread_safe and py_major == 3 and py_minor >= 13 ->
            {:warning,
             "Library #{library} is not thread-safe. " <>
               "Use :process profile even with Python 3.13+"}

          py_major == 3 and py_minor < 13 ->
            {:warning,
             "Python 3.13+ recommended for free-threading. " <>
               "Use :process profile with Python #{py_major}.#{py_minor}"}

          true ->
            :ok
        end

      {:error, :not_found} ->
        {:unknown, "Unknown library #{library}"}
    end
  end

  # Private helpers

  defp check_compatibility(library, info, profile) do
    case profile do
      :process ->
        # Process profile is always safe (isolation)
        :ok

      :thread ->
        if info.thread_safe do
          # Thread-safe, but may have configuration requirements
          if Map.has_key?(info, :workaround) do
            {:warning, "#{library} is thread-safe but requires configuration: #{info.workaround}"}
          else
            :ok
          end
        else
          # Not thread-safe
          {:warning,
           "#{library} is not thread-safe. #{info.notes}. Recommendation: #{info.recommendation}"}
        end
    end
  end
end
