defmodule MixSnakepitSetupTaskTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Snakepit.Setup
  alias Snakepit.Test.BootstrapRunner

  setup do
    original_python_executable = Application.get_env(:snakepit, :python_executable)

    tmp =
      System.tmp_dir!()
      |> Path.join("snakepit_setup_task_test_#{System.unique_integer([:positive])}")

    File.rm_rf(tmp)
    File.mkdir_p!(Path.join(tmp, "priv/python"))
    File.mkdir_p!(Path.join(tmp, "scripts"))

    File.write!(Path.join(tmp, "priv/python/requirements.txt"), "grpcio>=1.60.0\n")

    File.write!(Path.join(tmp, "scripts/setup_test_pythons.sh"), "#!/bin/bash\nexit 0\n")
    File.write!(Path.join(tmp, "priv/python/generate_grpc.sh"), "#!/bin/bash\nexit 0\n")

    Application.put_env(:snakepit, :bootstrap_project_root, tmp)
    Application.put_env(:snakepit, :bootstrap_runner, BootstrapRunner)

    Mix.shell(Mix.Shell.Process)
    BootstrapRunner.reset!()

    on_exit(fn ->
      Application.delete_env(:snakepit, :bootstrap_project_root)
      Application.delete_env(:snakepit, :bootstrap_runner)
      restore_env(:python_executable, original_python_executable)
      File.rm_rf(tmp)
      Mix.shell(Mix.Shell.IO)
    end)

    {:ok, tmp: tmp}
  end

  test "mix snakepit.setup delegates to bootstrap runner", %{tmp: tmp} do
    assert :ok = Setup.run([])

    assert_receive {:mix_shell, :info, ["✅ Snakepit bootstrap complete" <> _]}

    assert BootstrapRunner.calls() == [
             {:mix, "deps.get", []},
             {:cmd, python_cmd(), ["-m", "venv", ".venv"], [cd: tmp]},
             {:cmd, Path.join(tmp, ".venv/bin/pip"), ["install", "-r", requirements(tmp)],
              [cd: tmp]},
             {:cmd, Path.join(tmp, "scripts/setup_test_pythons.sh"), [], [cd: tmp]},
             {:cmd, Path.join(tmp, "priv/python/generate_grpc.sh"), [], [cd: tmp]}
           ]
  end

  defp python_cmd do
    System.find_executable("python3") || System.find_executable("python")
  end

  defp requirements(tmp), do: Path.join(tmp, "priv/python/requirements.txt")

  defp restore_env(key, nil), do: Application.delete_env(:snakepit, key)
  defp restore_env(key, value), do: Application.put_env(:snakepit, key, value)
end
