defmodule Snakepit.Test.PythonEnv do
  @moduledoc """
  Helper for managing Python environments in tests.

  Supports testing with different Python versions:
  - Python 3.12 (GIL present) via .venv
  - Python 3.13 (free-threading capable) via .venv-py313

  Usage in tests:
      setup [:python312]  # Requires Python 3.12
      setup [:python313]  # Requires Python 3.13
  """

  @py312_path ".venv/bin/python3"
  @py313_path ".venv-py313/bin/python3"

  def python_312_available? do
    File.exists?(Path.expand(@py312_path))
  end

  def python_313_available? do
    File.exists?(Path.expand(@py313_path))
  end

  def python_312_path, do: Path.expand(@py312_path)
  def python_313_path, do: Path.expand(@py313_path)

  def skip_unless_python_312(_context) do
    if python_312_available?() do
      configure_for_python(python_312_path())
      :ok
    else
      {:skip, "Python 3.12 venv not available (run: ./scripts/setup_test_pythons.sh)"}
    end
  end

  def skip_unless_python_313(_context) do
    if python_313_available?() do
      configure_for_python(python_313_path())
      :ok
    else
      {:skip, "Python 3.13 venv not available (run: ./scripts/setup_test_pythons.sh)"}
    end
  end

  def configure_for_python(python_path) do
    # Set environment so Snakepit uses specific Python
    System.put_env("SNAKEPIT_PYTHON", python_path)
    Application.put_env(:snakepit, :python_executable, python_path)
  end

  def reset_python_config do
    System.delete_env("SNAKEPIT_PYTHON")
    Application.delete_env(:snakepit, :python_executable)
  end
end
