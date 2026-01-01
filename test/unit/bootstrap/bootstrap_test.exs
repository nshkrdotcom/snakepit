defmodule Snakepit.BootstrapTest do
  use ExUnit.Case, async: false

  alias Snakepit.Bootstrap
  alias Snakepit.Test.BootstrapRunner

  setup do
    original_python_executable = Application.get_env(:snakepit, :python_executable)

    tmp =
      System.tmp_dir!()
      |> Path.join("snakepit_bootstrap_test_#{System.unique_integer([:positive])}")

    File.rm_rf(tmp)
    File.mkdir_p!(Path.join(tmp, "priv/python"))
    File.mkdir_p!(Path.join(tmp, "scripts"))

    File.write!(Path.join(tmp, "priv/python/requirements.txt"), "grpcio>=1.60.0\n")

    write_executable(Path.join(tmp, "scripts/setup_test_pythons.sh"))
    write_executable(Path.join(tmp, "priv/python/generate_grpc.sh"))

    on_exit(fn ->
      restore_env(:python_executable, original_python_executable)
      File.rm_rf(tmp)
    end)

    BootstrapRunner.reset!()

    {:ok, tmp: tmp}
  end

  test "run executes bootstrap steps in order", %{tmp: tmp} do
    assert :ok = Bootstrap.run(project_root: tmp, runner: BootstrapRunner)

    assert BootstrapRunner.calls() == [
             {:mix, "deps.get", []},
             {:cmd, python_cmd(), ["-m", "venv", ".venv"], [cd: tmp]},
             {:cmd, pip_cmd(tmp), ["install", "-q", "-r", requirements(tmp)], [cd: tmp]},
             {:cmd, script(tmp, "scripts/setup_test_pythons.sh"), [], [cd: tmp]},
             {:cmd, script(tmp, "priv/python/generate_grpc.sh"), [], [cd: tmp]}
           ]
  end

  test "existing venv skips recreation but still installs deps", %{tmp: tmp} do
    File.mkdir_p!(Path.join(tmp, ".venv"))

    assert :ok = Bootstrap.run(project_root: tmp, runner: BootstrapRunner)

    assert BootstrapRunner.calls() == [
             {:mix, "deps.get", []},
             {:cmd, pip_cmd(tmp), ["install", "-q", "-r", requirements(tmp)], [cd: tmp]},
             {:cmd, script(tmp, "scripts/setup_test_pythons.sh"), [], [cd: tmp]},
             {:cmd, script(tmp, "priv/python/generate_grpc.sh"), [], [cd: tmp]}
           ]
  end

  defp python_cmd, do: System.find_executable("python3") || System.find_executable("python")
  defp pip_cmd(tmp), do: Path.join(tmp, ".venv/bin/pip")
  defp requirements(tmp), do: Path.join(tmp, "priv/python/requirements.txt")
  defp script(tmp, rel), do: Path.join(tmp, rel)

  defp restore_env(key, nil), do: Application.delete_env(:snakepit, key)
  defp restore_env(key, value), do: Application.put_env(:snakepit, key, value)

  defp write_executable(path) do
    File.write!(path, "#!/bin/bash\nexit 0\n")
    File.chmod!(path, 0o755)
  end
end
