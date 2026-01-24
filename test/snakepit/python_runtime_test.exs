defmodule Snakepit.PythonRuntimeTest do
  use ExUnit.Case, async: false

  alias Snakepit.PythonRuntime

  setup do
    original = Application.get_env(:snakepit, :python)
    original_root = Application.get_env(:snakepit, :bootstrap_project_root)
    original_executable = Application.get_env(:snakepit, :python_executable)

    on_exit(fn ->
      restore_env(:python, original)
      restore_env(:bootstrap_project_root, original_root)
      restore_env(:python_executable, original_executable)
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:snakepit, key)
  defp restore_env(key, value), do: Application.put_env(:snakepit, key, value)

  test "prefers managed runtime when enabled" do
    root = Path.join(System.tmp_dir!(), "snakepit_python_runtime_#{System.unique_integer()}")
    runtime_dir = Path.join(root, "priv/snakepit/python")
    bin_dir = Path.join(runtime_dir, "bin")
    python_path = Path.join(bin_dir, "python3")

    File.mkdir_p!(bin_dir)
    File.write!(python_path, "#!/usr/bin/env bash\nexit 0\n")
    File.chmod!(python_path, 0o755)

    Application.put_env(:snakepit, :bootstrap_project_root, root)

    Application.put_env(:snakepit, :python, %{
      strategy: :uv,
      managed: true,
      runtime_dir: runtime_dir
    })

    assert {:ok, ^python_path, %{source: :managed}} = PythonRuntime.resolve_executable()
  end

  test "falls back to explicit python_executable override" do
    root = Path.join(System.tmp_dir!(), "snakepit_python_override_#{System.unique_integer()}")
    python_path = Path.join(root, "python3")

    File.mkdir_p!(root)
    File.write!(python_path, "#!/usr/bin/env bash\nexit 0\n")
    File.chmod!(python_path, 0o755)

    Application.put_env(:snakepit, :python, %{managed: false, strategy: :system})
    Application.put_env(:snakepit, :python_executable, python_path)

    assert {:ok, ^python_path, %{source: :override}} = PythonRuntime.resolve_executable()
  end

  test "invalid python_executable override returns error and does not crash runtime_env" do
    missing_path =
      Path.join(System.tmp_dir!(), "snakepit_missing_python_#{System.unique_integer()}")

    Application.put_env(:snakepit, :python, %{managed: false, strategy: :system})
    Application.put_env(:snakepit, :python_executable, missing_path)

    assert {:error, {:invalid_python_executable, ^missing_path}} =
             PythonRuntime.resolve_executable()

    assert PythonRuntime.runtime_env() == []
  end

  test "runtime_identity refreshes when python_executable override changes" do
    root = Path.join(System.tmp_dir!(), "snakepit_python_identity_#{System.unique_integer()}")
    File.mkdir_p!(root)

    python_a = Path.join(root, "python_a")
    python_b = Path.join(root, "python_b")

    File.write!(python_a, "#!/usr/bin/env bash\necho 3.12.3\n")
    File.chmod!(python_a, 0o755)
    File.write!(python_b, "#!/usr/bin/env bash\necho 3.12.4\n")
    File.chmod!(python_b, 0o755)

    Application.put_env(:snakepit, :python, %{managed: false, strategy: :system})
    Application.put_env(:snakepit, :python_executable, python_a)

    assert {:ok, %{path: ^python_a}} = PythonRuntime.runtime_identity()

    Application.put_env(:snakepit, :python_executable, python_b)
    assert {:ok, %{path: ^python_b}} = PythonRuntime.runtime_identity()
  end
end
