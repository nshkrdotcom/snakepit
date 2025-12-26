defmodule Snakepit.PythonVersion do
  @moduledoc """
  Detects the active Python runtime version and recommends worker profiles.
  """

  alias Snakepit.PythonRuntime

  @type version :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @min_supported {3, 8, 0}
  @free_threading_min {3, 13, 0}

  @spec detect() :: {:ok, version()} | {:error, term()}
  def detect do
    case PythonRuntime.resolve_executable() do
      {:ok, path, _meta} -> detect(path)
      {:error, :not_found} -> {:error, :python_not_found}
      {:error, :managed_missing} -> {:error, :python_not_found}
    end
  end

  @spec detect(binary()) :: {:ok, version()} | {:error, term()}
  def detect(path) when is_binary(path) do
    args = ["-c", "import sys; print('{}.{}.{}'.format(*sys.version_info[:3]))"]

    case System.cmd(path, args, stderr_to_stdout: true) do
      {output, 0} ->
        parse_version(output)

      {output, _code} ->
        {:error, {:python_failed, String.trim(output)}}
    end
  rescue
    _error -> {:error, :python_not_found}
  end

  @spec supports_free_threading?(version()) :: boolean()
  def supports_free_threading?(version) do
    version >= @free_threading_min
  end

  @spec recommend_profile() :: :process | :thread
  def recommend_profile do
    case detect() do
      {:ok, version} -> recommend_profile(version)
      _ -> :process
    end
  end

  @spec recommend_profile(version()) :: :process | :thread
  def recommend_profile(version) do
    if supports_free_threading?(version), do: :thread, else: :process
  end

  @spec validate() :: :ok | {:error, term()}
  def validate do
    case detect() do
      {:ok, version} ->
        if version >= @min_supported do
          :ok
        else
          {:error, {:unsupported_version, version}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_version(output) do
    version = String.trim(output)

    case Regex.run(~r/(\d+)\.(\d+)\.(\d+)/, version) do
      [_, major, minor, patch] ->
        {:ok, {String.to_integer(major), String.to_integer(minor), String.to_integer(patch)}}

      _ ->
        {:error, {:invalid_version, version}}
    end
  end
end
