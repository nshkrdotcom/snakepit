defmodule Snakepit.PythonPackagesTest do
  use ExUnit.Case, async: false

  alias Snakepit.PackageError
  alias Snakepit.PythonPackages

  defmodule FakeRunner do
    @moduledoc false

    def cmd(command, args, opts) do
      send(self(), {:cmd, command, args, opts})
      handler = Process.get(:python_packages_handler)

      if is_function(handler, 3) do
        handler.(command, args, opts)
      else
        {"", 0}
      end
    end
  end

  setup do
    original_packages = Application.get_env(:snakepit, :python_packages)
    original_python = Application.get_env(:snakepit, :python)
    original_python_executable = Application.get_env(:snakepit, :python_executable)
    original_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env(:python_packages, original_packages)
      restore_env(:python, original_python)
      restore_env(:python_executable, original_python_executable)

      if original_path do
        System.put_env("PATH", original_path)
      else
        System.delete_env("PATH")
      end

      Process.delete(:python_packages_handler)
    end)

    python_path =
      Path.join(System.tmp_dir!(), "snakepit_fake_python_#{System.unique_integer([:positive])}")

    File.write!(python_path, "#!/usr/bin/env bash\nexit 0\n")
    File.chmod!(python_path, 0o755)

    Application.put_env(:snakepit, :python_executable, python_path)
    Application.put_env(:snakepit, :python, %{managed: false, strategy: :system})

    Application.put_env(:snakepit, :python_packages,
      installer: :pip,
      runner: FakeRunner,
      env_dir: false
    )

    {:ok, python_path: python_path}
  end

  defp restore_env(key, nil), do: Application.delete_env(:snakepit, key)
  defp restore_env(key, value), do: Application.put_env(:snakepit, key, value)

  test "check_installed/2 returns :all_installed when packages are present",
       %{python_path: python_path} do
    Process.put(:python_packages_handler, fn
      ^python_path, ["-m", "pip", "show", "numpy"], _opts -> {"Name: numpy\n", 0}
      ^python_path, ["-m", "pip", "show", "pandas"], _opts -> {"Name: pandas\n", 0}
    end)

    assert {:ok, :all_installed} =
             PythonPackages.check_installed(["numpy~=1.26", "pandas>=2.0"])

    assert_receive {:cmd, ^python_path, ["-m", "pip", "show", "numpy"], _opts}
    assert_receive {:cmd, ^python_path, ["-m", "pip", "show", "pandas"], _opts}
  end

  test "check_installed/2 returns missing requirements when packages are absent",
       %{python_path: python_path} do
    Process.put(:python_packages_handler, fn
      ^python_path, ["-m", "pip", "show", "numpy"], _opts -> {"Name: numpy\n", 0}
      ^python_path, ["-m", "pip", "show", "pandas"], _opts -> {"", 1}
    end)

    assert {:ok, {:missing, ["pandas>=2.0"]}} =
             PythonPackages.check_installed(["numpy~=1.26", "pandas>=2.0"])

    assert_receive {:cmd, ^python_path, ["-m", "pip", "show", "numpy"], _opts}
    assert_receive {:cmd, ^python_path, ["-m", "pip", "show", "pandas"], _opts}
  end

  test "ensure!/2 installs missing packages via pip", %{python_path: python_path} do
    Process.put(:python_packages_handler, fn
      ^python_path, ["-m", "pip", "show", "numpy"], _opts ->
        {"", 1}

      ^python_path, ["-m", "pip", "install", "--upgrade", "--quiet", "numpy~=1.26"], _opts ->
        {"ok", 0}
    end)

    assert :ok =
             PythonPackages.ensure!({:list, ["numpy~=1.26"]},
               upgrade: true,
               quiet: true,
               timeout: 1_234
             )

    assert_receive {:cmd, ^python_path, ["-m", "pip", "show", "numpy"], _opts}

    assert_receive {:cmd, ^python_path,
                    ["-m", "pip", "install", "--upgrade", "--quiet", "numpy~=1.26"], opts}

    assert opts[:timeout] == 1_234
  end

  test "ensure!/2 raises PackageError on install failure", %{python_path: python_path} do
    Process.put(:python_packages_handler, fn
      ^python_path, ["-m", "pip", "show", "badpkg"], _opts -> {"", 1}
      ^python_path, ["-m", "pip", "install", "badpkg"], _opts -> {"error", 2}
    end)

    error =
      assert_raise PackageError, fn ->
        PythonPackages.ensure!({:list, ["badpkg"]})
      end

    assert error.type == :install_failed
  end

  test "lock_metadata/2 returns versions for requested packages", %{python_path: python_path} do
    Process.put(:python_packages_handler, fn
      ^python_path, ["-m", "pip", "freeze"], _opts ->
        {"numpy==1.26.4\nscipy==1.11.4\n", 0}
    end)

    assert {:ok,
            %{
              "numpy" => %{version: "1.26.4", hash: nil},
              "scipy" => %{version: "1.11.4", hash: nil}
            }} = PythonPackages.lock_metadata(["numpy~=1.26", "scipy>=1.11"])
  end

  test "installer/0 prefers uv when available" do
    tmp_dir = Path.join(System.tmp_dir!(), "snakepit_uv_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    uv_path = Path.join(tmp_dir, "uv")
    File.write!(uv_path, "#!/usr/bin/env bash\nexit 0\n")
    File.chmod!(uv_path, 0o755)

    System.put_env("PATH", tmp_dir)

    Application.put_env(:snakepit, :python_packages,
      installer: :auto,
      runner: FakeRunner,
      env_dir: false
    )

    assert :uv == PythonPackages.installer()
  end

  test "installer/0 falls back to pip when uv is unavailable" do
    System.put_env("PATH", Path.join(System.tmp_dir!(), "snakepit_no_uv"))

    Application.put_env(:snakepit, :python_packages,
      installer: :auto,
      runner: FakeRunner,
      env_dir: false
    )

    assert :pip == PythonPackages.installer()
  end

  test "ensure!/2 parses requirements files and ignores comments", %{python_path: python_path} do
    requirements_path =
      Path.join(
        System.tmp_dir!(),
        "snakepit_requirements_#{System.unique_integer([:positive])}.txt"
      )

    File.write!(requirements_path, "# comment\nnumpy~=1.26\n\nscipy>=1.11\n")

    Process.put(:python_packages_handler, fn
      ^python_path, ["-m", "pip", "show", "numpy"], _opts -> {"Name: numpy\n", 0}
      ^python_path, ["-m", "pip", "show", "scipy"], _opts -> {"Name: scipy\n", 0}
    end)

    assert :ok = PythonPackages.ensure!({:file, requirements_path})

    assert_receive {:cmd, ^python_path, ["-m", "pip", "show", "numpy"], _opts}
    assert_receive {:cmd, ^python_path, ["-m", "pip", "show", "scipy"], _opts}
    refute_receive {:cmd, ^python_path, ["-m", "pip", "install" | _], _opts}
  end

  test "check_installed/2 uses uv when configured", %{python_path: python_path} do
    Application.put_env(:snakepit, :python, %{managed: false, strategy: :system, uv_path: "uv"})

    Application.put_env(:snakepit, :python_packages,
      installer: :uv,
      runner: FakeRunner,
      env_dir: false
    )

    Process.put(:python_packages_handler, fn
      "uv", ["pip", "show", "numpy", "--python", ^python_path], _opts -> {"Name: numpy\n", 0}
    end)

    assert {:ok, :all_installed} = PythonPackages.check_installed(["numpy~=1.26"])

    assert_receive {:cmd, "uv", ["pip", "show", "numpy", "--python", ^python_path], _opts}
  end
end
