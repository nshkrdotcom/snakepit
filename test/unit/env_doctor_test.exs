defmodule Snakepit.EnvDoctorTest do
  use ExUnit.Case, async: false

  alias Snakepit.EnvDoctor
  alias Snakepit.Test.CommandRunner

  setup do
    tmp =
      System.tmp_dir!()
      |> Path.join("snakepit_env_doctor_test_#{System.unique_integer([:positive])}")

    File.rm_rf(tmp)

    File.mkdir_p!(Path.join(tmp, ".venv/bin"))
    File.mkdir_p!(Path.join(tmp, ".venv-py313/bin"))
    File.mkdir_p!(Path.join(tmp, "priv/python"))

    write_exec(Path.join(tmp, ".venv/bin/python3"))
    write_exec(Path.join(tmp, ".venv-py313/bin/python3"))

    File.write!(
      Path.join(tmp, "priv/python/grpc_server.py"),
      "#!/usr/bin/env python3\nprint('ok')\n"
    )

    Application.put_env(:snakepit, :grpc_port, 55_000 + :rand.uniform(1_000))

    CommandRunner.reset!()

    on_exit(fn ->
      Application.delete_env(:snakepit, :grpc_port)
      File.rm_rf(tmp)
    end)

    {:ok, root: tmp, python: Path.join(tmp, ".venv/bin/python3")}
  end

  test "run returns ok when every check passes", %{root: root, python: python} do
    CommandRunner.reset!([:ok, :ok, :ok])

    assert {:ok, results} =
             EnvDoctor.run(
               project_root: root,
               python_path: python,
               runner: CommandRunner,
               require_python_313?: true
             )

    assert Enum.all?(results, &(&1.status in [:ok]))

    assert [
             {:cmd, ^python, ["-c", "import grpc"], [cd: ^root, env: env1]},
             {:cmd, ^python, [script_path, "--health-check" | _rest], [cd: ^root, env: env2]},
             {:cmd, ^python, [script_path, "--health-check" | _rest2], [cd: ^root, env: env3]}
           ] = CommandRunner.calls()

    assert script_path == Path.join(root, "priv/python/grpc_server.py")
    assert is_list(env1)
    assert is_list(env2)
    assert is_list(env3)
  end

  test "run flags missing python executable", %{root: root} do
    assert {:error, results} =
             EnvDoctor.run(
               project_root: root,
               python_path: Path.join(root, "missing"),
               runner: CommandRunner
             )

    assert %{name: :python_exec, status: :error, message: message} = hd(results)
    assert message =~ "mix snakepit.setup"

    assert CommandRunner.calls() == []
  end

  test "run surfaces grpc import failure", %{root: root, python: python} do
    CommandRunner.reset!([{:error, :no_grpc}, :ok])

    assert {:error, results} =
             EnvDoctor.run(project_root: root, python_path: python, runner: CommandRunner)

    assert Enum.any?(results, fn
             %{name: :grpc_import, status: :error} -> true
             _ -> false
           end)
  end

  test "ensure_python!/1 raises on failed health check", %{root: root, python: python} do
    CommandRunner.reset!([:ok, {:error, :health_failed}, :ok])

    assert_raise RuntimeError, fn ->
      EnvDoctor.ensure_python!(
        project_root: root,
        python_path: python,
        runner: CommandRunner
      )
    end
  end

  defp write_exec(path) do
    File.write!(path, "#!/usr/bin/env bash\nexit 0\n")
    File.chmod!(path, 0o755)
  end
end
