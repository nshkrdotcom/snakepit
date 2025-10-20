defmodule Snakepit.PythonEnvironmentTest do
  use ExUnit.Case, async: true

  alias Snakepit.PythonEnvironment
  alias Snakepit.PythonEnvironment.Command

  setup do
    original_env = Application.get_env(:snakepit, :python_environment)
    original_exec = Application.get_env(:snakepit, :python_executable)

    on_exit(fn ->
      if original_env do
        Application.put_env(:snakepit, :python_environment, original_env)
      else
        Application.delete_env(:snakepit, :python_environment)
      end

      if original_exec do
        Application.put_env(:snakepit, :python_executable, original_exec)
      else
        Application.delete_env(:snakepit, :python_executable)
      end
    end)

    :ok
  end

  test "native environment respects configured python_executable" do
    Application.put_env(:snakepit, :python_environment, :native)
    Application.put_env(:snakepit, :python_executable, "/tmp/custom-python")

    assert {:ok, %Command{executable: "/tmp/custom-python", args: []} = command} =
             PythonEnvironment.resolve(%{})

    assert command.path_mappings == []
    assert command.set_host_cwd?
  end

  test "docker environment builds docker exec command" do
    docker_binary =
      System.find_executable("sh") ||
        System.find_executable("true") ||
        "/bin/sh"

    Application.put_env(:snakepit, :python_environment, {:docker, %{container: "phoenix"}})

    config = %{
      container: "phoenix",
      docker_binary: docker_binary,
      python_path: "/opt/venv/bin/python3",
      exec_prefix: ["--config"],
      pre_python_args: ["--workdir", "/app"],
      python_args: ["-m"],
      env: [{"FOO", "bar"}],
      path_mappings: [%{from: "/host/app", to: "/app"}],
      validate?: false
    }

    assert {:ok, %Command{} = command} =
             Snakepit.PythonEnvironment.Docker.resolve(%{}, config)

    assert command.executable == docker_binary

    assert command.args == [
             "--config",
             "exec",
             "-i",
             "phoenix",
             "--workdir",
             "/app",
             "/opt/venv/bin/python3",
             "-m"
           ]

    assert command.env == [{"FOO", "bar"}]
    assert command.path_mappings == [%{from: "/host/app", to: "/app"}]
    refute command.set_host_cwd?
  end

  test "command path mapping rewrites to container path" do
    command = %Command{
      executable: "python",
      path_mappings: [%{from: "/workspace", to: "/app"}]
    }

    assert Command.apply_path(command, "/workspace/nordic/priv/python/grpc_server.py") ==
             "/app/nordic/priv/python/grpc_server.py"

    assert Command.apply_path(command, "/nothing/else.py") == "/nothing/else.py"
  end
end
