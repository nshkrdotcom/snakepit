defmodule Snakepit.Compatibility do
  @moduledoc """
  Thread-safety compatibility matrix for common Python libraries.

  > #### Legacy Optional Module {: .warning}
  >
  > `Snakepit` does not call this module internally. It remains available for
  > compatibility and may be removed in `v0.16.0` or later.
  >
  > Prefer explicit worker-profile and adapter-level thread-safety
  > configuration in your host application.
  """

  alias Snakepit.Internal.Deprecation

  @type thread_safety :: true | false | :conditional
  @type library_info :: %{
          thread_safe: thread_safety(),
          notes: String.t()
        }

  @legacy_replacement "Use worker profile and adapter-level thread-safety settings"
  @legacy_remove_after "v0.16.0"

  @libraries %{
    "numpy" => %{thread_safe: true, notes: "Releases GIL during computation"},
    "scipy" => %{thread_safe: true, notes: "Releases GIL for numerical ops"},
    "torch" => %{thread_safe: true, notes: "Configure with torch.set_num_threads/1"},
    "tensorflow" => %{thread_safe: true, notes: "Use tf.config.threading APIs"},
    "scikit-learn" => %{thread_safe: :conditional, notes: "Set n_jobs=1 per estimator"},
    "polars" => %{thread_safe: true, notes: "Thread-safe DataFrame library"},
    "requests" => %{thread_safe: true, notes: "Use separate Session per thread"},
    "httpx" => %{thread_safe: true, notes: "Async-first; thread-safe clients"},
    "aiohttp" => %{thread_safe: :conditional, notes: "One ClientSession per thread"},
    "grpcio" => %{thread_safe: true, notes: "Thread-safe client with shared channels"},
    "numexpr" => %{thread_safe: true, notes: "Releases GIL for expression evaluation"},
    "onnxruntime" => %{thread_safe: true, notes: "Thread-safe inference sessions"},
    "jax" => %{thread_safe: :conditional, notes: "Avoid shared mutable state"},
    "opencv" => %{thread_safe: :conditional, notes: "Avoid shared mutable state"},
    "pillow" => %{thread_safe: :conditional, notes: "Use separate Image objects"},
    "pandas" => %{thread_safe: false, notes: "Not thread-safe; lock DataFrame ops"},
    "matplotlib" => %{thread_safe: false, notes: "Global state; prefer process mode"},
    "sqlite3" => %{thread_safe: false, notes: "Use separate connections per thread"},
    "sqlalchemy" => %{thread_safe: :conditional, notes: "Use per-thread sessions"},
    "spacy" => %{thread_safe: false, notes: "Models share global state"},
    "fasttext" => %{thread_safe: false, notes: "Model objects are not thread-safe"},
    "xgboost" => %{thread_safe: :conditional, notes: "Set num_threads and avoid shared state"},
    "lightgbm" => %{thread_safe: :conditional, notes: "Set num_threads and avoid shared state"},
    "cupy" => %{thread_safe: :conditional, notes: "Manage CUDA context per thread"},
    "faiss" => %{thread_safe: :conditional, notes: "Avoid shared index mutation"},
    "ray" => %{thread_safe: false, notes: "Prefer process-based workers"},
    "celery" => %{thread_safe: false, notes: "Use process-based workers"}
  }

  @spec check(String.t() | atom(), :thread | :process) ::
          {:ok, String.t()} | {:warning, String.t()} | {:error, String.t()}
  def check(library, profile) when profile in [:thread, :process] do
    mark_legacy_usage()

    name = normalize_name(library)

    case Map.get(@libraries, name) do
      nil ->
        {:warning, "Unknown library: #{name}"}

      _info when profile == :process ->
        {:ok, "Process profile isolates workers"}

      %{thread_safe: true} ->
        {:ok, "Thread-safe"}

      %{thread_safe: false, notes: notes} ->
        {:error, "Not thread-safe: #{notes}"}

      %{thread_safe: :conditional, notes: notes} ->
        {:warning, "Conditionally thread-safe: #{notes}"}
    end
  end

  def check(_library, _profile), do: {:error, "Unknown profile"}

  @spec get_library_info(String.t() | atom()) :: library_info() | nil
  def get_library_info(library) do
    mark_legacy_usage()

    name = normalize_name(library)
    Map.get(@libraries, name)
  end

  @spec list_all(:thread_safe | :thread_unsafe | :conditional | :all) :: [String.t()]
  def list_all(:thread_safe) do
    mark_legacy_usage()
    select_names(fn {_name, info} -> info.thread_safe == true end)
  end

  def list_all(:thread_unsafe) do
    mark_legacy_usage()
    select_names(fn {_name, info} -> info.thread_safe == false end)
  end

  def list_all(:conditional) do
    mark_legacy_usage()
    select_names(fn {_name, info} -> info.thread_safe == :conditional end)
  end

  def list_all(:all) do
    mark_legacy_usage()
    Map.keys(@libraries)
  end

  def list_all(_) do
    mark_legacy_usage()
    []
  end

  @spec generate_report([String.t() | atom()], :thread | :process) ::
          {:ok, map()} | {:error, term()}
  def generate_report(libraries, profile) when is_list(libraries) do
    mark_legacy_usage()

    report =
      Enum.reduce(libraries, %{safe: [], unsafe: [], conditional: [], unknown: []}, fn library,
                                                                                       acc ->
        name = normalize_name(library)

        case Map.get(@libraries, name) do
          nil ->
            Map.update!(acc, :unknown, &[name | &1])

          %{thread_safe: true} ->
            Map.update!(acc, :safe, &[name | &1])

          %{thread_safe: false} ->
            Map.update!(acc, :unsafe, &[name | &1])

          %{thread_safe: :conditional} ->
            Map.update!(acc, :conditional, &[name | &1])
        end
      end)
      |> Map.put(:profile, profile)
      |> normalize_report()

    {:ok, report}
  end

  def generate_report(_libraries, _profile), do: {:error, :invalid_libraries}

  defp normalize_name(library) when is_atom(library),
    do: library |> Atom.to_string() |> normalize_name()

  defp normalize_name(library) when is_binary(library) do
    library
    |> String.trim()
    |> String.downcase()
    |> String.replace("_", "-")
  end

  defp select_names(fun) do
    @libraries
    |> Enum.filter(fun)
    |> Enum.map(fn {name, _info} -> name end)
  end

  defp normalize_report(report) do
    report
    |> Map.update!(:safe, &Enum.reverse/1)
    |> Map.update!(:unsafe, &Enum.reverse/1)
    |> Map.update!(:conditional, &Enum.reverse/1)
    |> Map.update!(:unknown, &Enum.reverse/1)
  end

  defp mark_legacy_usage do
    Deprecation.emit_legacy_module_used(__MODULE__,
      replacement: @legacy_replacement,
      remove_after: @legacy_remove_after
    )
  end
end
