defmodule Snakepit.PythonVersion do
  @moduledoc """
  Python version detection and compatibility checking.

  This module detects the Python version and provides recommendations
  for which worker profile to use based on Python capabilities.

  ## Python 3.13+ Free-Threading

  Python 3.13 introduced experimental free-threading mode (PEP 703),
  removing the Global Interpreter Lock (GIL). This enables true multi-threaded
  parallelism within a single Python process.

  ## Usage

      # Detect Python version
      {:ok, {3, 13, 0}} = Snakepit.PythonVersion.detect()

      # Check free-threading support
      true = Snakepit.PythonVersion.supports_free_threading?({3, 13, 0})

      # Get profile recommendation
      :thread = Snakepit.PythonVersion.recommend_profile()

  ## Version Support

  - Python 3.8-3.12: Use `:process` profile (GIL present)
  - Python 3.13+: Can use `:thread` profile (free-threading available)
  """

  require Logger
  alias Snakepit.Logger, as: SLog

  @type version ::
          {major :: non_neg_integer(), minor :: non_neg_integer(), patch :: non_neg_integer()}
  @type profile :: :process | :thread

  @doc """
  Detect the Python version.

  Returns `{:ok, {major, minor, patch}}` or `{:error, reason}`.

  ## Examples

      iex> Snakepit.PythonVersion.detect()
      {:ok, {3, 12, 0}}

      iex> Snakepit.PythonVersion.detect("python3.13")
      {:ok, {3, 13, 0}}
  """
  @spec detect(executable :: String.t()) :: {:ok, version()} | {:error, term()}
  def detect(executable \\ "python3") do
    case System.cmd(executable, ["--version"], stderr_to_stdout: true) do
      {output, 0} ->
        parse_version(output)

      {_output, _code} ->
        {:error, :python_not_found}
    end
  rescue
    _ ->
      {:error, :python_not_found}
  end

  @doc """
  Check if a Python version supports free-threading mode.

  Free-threading (no-GIL mode) is available in Python 3.13+.

  ## Examples

      iex> Snakepit.PythonVersion.supports_free_threading?({3, 13, 0})
      true

      iex> Snakepit.PythonVersion.supports_free_threading?({3, 12, 0})
      false
  """
  @spec supports_free_threading?(version()) :: boolean()
  def supports_free_threading?({major, minor, _patch}) do
    major == 3 and minor >= 13
  end

  @doc """
  Recommend a worker profile based on the detected Python version.

  - Python 3.8-3.12: Returns `:process` (GIL compatibility)
  - Python 3.13+: Returns `:thread` (free-threading capable)
  - Cannot detect: Returns `:process` (safe default)

  ## Examples

      iex> Snakepit.PythonVersion.recommend_profile()
      :thread  # if Python 3.13+ detected

      iex> Snakepit.PythonVersion.recommend_profile({3, 12, 0})
      :process
  """
  @spec recommend_profile() :: profile()
  @spec recommend_profile(version()) :: profile()
  def recommend_profile do
    case detect() do
      {:ok, version} ->
        recommend_profile(version)

      {:error, _} ->
        SLog.warning(
          "Could not detect Python version. Defaulting to :process profile for safety."
        )

        :process
    end
  end

  def recommend_profile(version) when is_tuple(version) do
    if supports_free_threading?(version) do
      :thread
    else
      :process
    end
  end

  @doc """
  Get detailed Python environment information.

  Returns a map with version info, capabilities, and recommendations.

  ## Examples

      iex> Snakepit.PythonVersion.get_info()
      {:ok, %{
        version: {3, 13, 0},
        version_string: "Python 3.13.0",
        supports_free_threading: true,
        recommended_profile: :thread,
        gil_status: "removable"
      }}
  """
  @spec get_info(executable :: String.t()) :: {:ok, map()} | {:error, term()}
  def get_info(executable \\ "python3") do
    case detect(executable) do
      {:ok, version} ->
        {major, minor, patch} = version

        info = %{
          version: version,
          version_string: "Python #{major}.#{minor}.#{patch}",
          supports_free_threading: supports_free_threading?(version),
          recommended_profile: recommend_profile(version),
          gil_status: gil_status(version),
          executable: executable
        }

        {:ok, info}

      error ->
        error
    end
  end

  @doc """
  Check if the current Python version meets minimum requirements.

  Snakepit requires Python 3.8 or higher.

  ## Examples

      iex> Snakepit.PythonVersion.meets_requirements?({3, 8, 0})
      true

      iex> Snakepit.PythonVersion.meets_requirements?({3, 7, 0})
      false
  """
  @spec meets_requirements?(version()) :: boolean()
  def meets_requirements?({major, minor, _patch}) do
    major == 3 and minor >= 8
  end

  @doc """
  Validate Python environment and provide warnings if needed.

  Returns `:ok` if environment is valid, or `{:warning, messages}` if there
  are compatibility concerns.

  ## Examples

      iex> Snakepit.PythonVersion.validate()
      :ok

      iex> Snakepit.PythonVersion.validate()
      {:warning, ["Python 3.7 detected. Snakepit requires Python 3.8+"]}
  """
  @spec validate() :: :ok | {:warning, [String.t()]}
  def validate do
    case detect() do
      {:ok, version} ->
        if meets_requirements?(version) do
          :ok
        else
          {major, minor, patch} = version

          {:warning,
           [
             "Python #{major}.#{minor}.#{patch} detected. Snakepit requires Python 3.8+",
             "Please upgrade Python to ensure compatibility"
           ]}
        end

      {:error, :python_not_found} ->
        {:warning,
         [
           "Python executable not found",
           "Ensure python3 is in your PATH"
         ]}

      {:error, reason} ->
        {:warning, ["Python detection failed: #{inspect(reason)}"]}
    end
  end

  # Private functions

  defp parse_version(output) do
    # Expected format: "Python 3.12.0" or "Python 3.13.0rc1"
    case Regex.run(~r/Python (\d+)\.(\d+)\.(\d+)/, output) do
      [_, major, minor, patch] ->
        {:ok, {String.to_integer(major), String.to_integer(minor), String.to_integer(patch)}}

      nil ->
        {:error, {:parse_error, output}}
    end
  end

  defp gil_status({major, minor, _patch}) do
    cond do
      major == 3 and minor >= 13 -> "removable (free-threading mode available)"
      major == 3 and minor >= 8 -> "present (required for this version)"
      true -> "present"
    end
  end
end
