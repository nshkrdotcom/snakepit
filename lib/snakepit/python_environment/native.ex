defmodule Snakepit.PythonEnvironment.Native do
  @moduledoc """
  Default Python environment resolver that mirrors the legacy behaviour.

  Prefers explicit configuration (`pool.python_executable` or
  `config :snakepit, python_executable`), falls back to the `SNAKEPIT_PYTHON`
  environment variable, then attempts to locate a virtual environment in the
  current project before finally deferring to `python3/python` on the system
  `PATH`.
  """

  alias Snakepit.Logger, as: SLog
  alias Snakepit.PythonEnvironment.Command

  @spec resolve(map(), map()) :: {:ok, Command.t()} | {:error, term()}
  def resolve(worker_config, _config \\ %{}) do
    case executable_path(worker_config) do
      nil ->
        {:error, :python_executable_not_found}

      path ->
        SLog.debug("Native Python executable resolved: #{path}")

        {:ok,
         %Command{
           executable: path,
           set_host_cwd?: true,
           metadata: %{environment: :native}
         }}
    end
  end

  defp executable_path(worker_config) do
    Map.get(worker_config, :python_executable) ||
      Application.get_env(:snakepit, :python_executable) ||
      System.get_env("SNAKEPIT_PYTHON") ||
      find_venv_python() ||
      System.find_executable("python3") ||
      System.find_executable("python")
  end

  defp find_venv_python do
    candidates = [
      ".venv/bin/python3",
      "../.venv/bin/python3",
      System.get_env("VIRTUAL_ENV") && Path.join(System.get_env("VIRTUAL_ENV"), "bin/python3")
    ]

    Enum.find_value(candidates, fn
      nil ->
        nil

      candidate ->
        expanded = Path.expand(candidate)
        if File.exists?(expanded), do: expanded
    end)
  end
end
