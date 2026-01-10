defmodule Mix.Tasks.Snakepit.PythonTest do
  @shortdoc "Bootstrap and run Snakepit Python tests"
  @moduledoc """
  Bootstraps the Snakepit Python environment and runs the Python test suite.

  Usage:

      mix snakepit.python_test
      mix snakepit.python_test -- --maxfail=1

  Options:
    * `--no-bootstrap` - Skip `mix snakepit.setup`
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, pytest_args, _} =
      OptionParser.parse(args, strict: [no_bootstrap: :boolean])

    unless opts[:no_bootstrap] do
      Mix.Task.run("snakepit.setup")
    end

    {python, env, project_root} = resolve_python_env()
    tests_dir = Path.join(project_root, "priv/python/tests")

    cmd_args = ["-m", "pytest", tests_dir] ++ pytest_args

    {output, status} =
      System.cmd(python, cmd_args,
        env: env,
        cd: project_root,
        stderr_to_stdout: true
      )

    if output != "" do
      Mix.shell().info(output)
    end

    if status != 0 do
      Mix.raise("Python tests failed with exit code #{status}")
    end
  end

  defp resolve_python_env do
    project_root = File.cwd!()
    priv_python = Path.join(project_root, "priv/python")
    venv_python = Path.join(project_root, ".venv/bin/python")

    python =
      System.get_env("SNAKEPIT_TEST_PYTHON") ||
        if(File.exists?(venv_python), do: venv_python, else: nil) ||
        Snakepit.PythonRuntime.executable_path() ||
        System.find_executable("python3") ||
        System.find_executable("python") ||
        Mix.raise(
          "Python executable not found; run mix snakepit.setup or set SNAKEPIT_TEST_PYTHON"
        )

    env = [{"PYTHONPATH", priv_python}]

    {python, env, project_root}
  end
end
