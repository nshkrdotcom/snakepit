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

    # Create fake uv executable
    tmp_dir = Path.join(System.tmp_dir!(), "snakepit_uv_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    uv_path = Path.join(tmp_dir, "uv")
    File.write!(uv_path, "#!/usr/bin/env bash\nexit 0\n")
    File.chmod!(uv_path, 0o755)

    Application.put_env(:snakepit, :python_executable, python_path)

    Application.put_env(:snakepit, :python, %{managed: false, strategy: :system, uv_path: uv_path})

    Application.put_env(:snakepit, :python_packages,
      runner: FakeRunner,
      env_dir: false
    )

    {:ok, python_path: python_path, uv_path: uv_path}
  end

  defp restore_env(key, nil), do: Application.delete_env(:snakepit, key)
  defp restore_env(key, value), do: Application.put_env(:snakepit, key, value)

  describe "check_installed/2" do
    test "returns :all_installed when packages satisfy version requirements",
         %{python_path: python_path, uv_path: uv_path} do
      Process.put(:python_packages_handler, fn
        ^uv_path,
        ["pip", "install", "--dry-run", "--python", ^python_path, "numpy~=1.26"],
        _opts ->
          # No "Would install" means package is satisfied
          {"Audited 1 package in 5ms", 0}

        ^uv_path,
        ["pip", "install", "--dry-run", "--python", ^python_path, "pandas>=2.0"],
        _opts ->
          {"Audited 1 package in 5ms", 0}
      end)

      assert {:ok, :all_installed} =
               PythonPackages.check_installed(["numpy~=1.26", "pandas>=2.0"])

      assert_receive {:cmd, ^uv_path,
                      ["pip", "install", "--dry-run", "--python", ^python_path, "numpy~=1.26"],
                      _opts}

      assert_receive {:cmd, ^uv_path,
                      ["pip", "install", "--dry-run", "--python", ^python_path, "pandas>=2.0"],
                      _opts}
    end

    test "returns missing requirements when packages need installation or upgrade",
         %{python_path: python_path, uv_path: uv_path} do
      Process.put(:python_packages_handler, fn
        ^uv_path,
        ["pip", "install", "--dry-run", "--python", ^python_path, "numpy~=1.26"],
        _opts ->
          {"Audited 1 package in 5ms", 0}

        ^uv_path,
        ["pip", "install", "--dry-run", "--python", ^python_path, "pandas>=2.0"],
        _opts ->
          # "Would install" means package needs to be installed
          {"Would install pandas==2.1.0", 0}
      end)

      assert {:ok, {:missing, ["pandas>=2.0"]}} =
               PythonPackages.check_installed(["numpy~=1.26", "pandas>=2.0"])
    end

    test "detects version mismatches that need upgrade",
         %{python_path: python_path, uv_path: uv_path} do
      Process.put(:python_packages_handler, fn
        ^uv_path,
        ["pip", "install", "--dry-run", "--python", ^python_path, "grpcio>=1.76.0"],
        _opts ->
          # "Would upgrade" means installed version doesn't satisfy requirement
          {"Would upgrade grpcio from 1.67.1 to 1.76.0", 0}
      end)

      assert {:ok, {:missing, ["grpcio>=1.76.0"]}} =
               PythonPackages.check_installed(["grpcio>=1.76.0"])
    end

    test "handles complex version specifiers",
         %{python_path: python_path, uv_path: uv_path} do
      Process.put(:python_packages_handler, fn
        ^uv_path, ["pip", "install", "--dry-run", "--python", ^python_path, requirement], _opts ->
          case requirement do
            "numpy>=1.26,<2.0" -> {"Audited 1 package in 5ms", 0}
            "scipy~=1.11" -> {"Audited 1 package in 5ms", 0}
            "torch[cuda]>=2.0" -> {"Audited 1 package in 5ms", 0}
            _ -> {"Would install #{requirement}", 0}
          end
      end)

      assert {:ok, :all_installed} =
               PythonPackages.check_installed([
                 "numpy>=1.26,<2.0",
                 "scipy~=1.11",
                 "torch[cuda]>=2.0"
               ])
    end
  end

  describe "ensure!/2" do
    test "installs missing packages via uv", %{python_path: python_path, uv_path: uv_path} do
      Process.put(:python_packages_handler, fn
        ^uv_path,
        ["pip", "install", "--dry-run", "--python", ^python_path, "numpy~=1.26"],
        _opts ->
          {"Would install numpy==1.26.4", 0}

        ^uv_path,
        ["pip", "install", "--python", ^python_path, "--upgrade", "--quiet", "numpy~=1.26"],
        _opts ->
          {"ok", 0}
      end)

      assert :ok =
               PythonPackages.ensure!({:list, ["numpy~=1.26"]},
                 upgrade: true,
                 quiet: true,
                 timeout: 1_234
               )

      assert_receive {:cmd, ^uv_path,
                      ["pip", "install", "--dry-run", "--python", ^python_path, "numpy~=1.26"],
                      _opts}

      assert_receive {:cmd, ^uv_path,
                      [
                        "pip",
                        "install",
                        "--python",
                        ^python_path,
                        "--upgrade",
                        "--quiet",
                        "numpy~=1.26"
                      ], opts}

      assert opts[:timeout] == 1_234
    end

    test "skips installation when all packages satisfy requirements",
         %{python_path: python_path, uv_path: uv_path} do
      Process.put(:python_packages_handler, fn
        ^uv_path, ["pip", "install", "--dry-run", "--python", ^python_path, _req], _opts ->
          {"Audited 1 package in 5ms", 0}
      end)

      assert :ok = PythonPackages.ensure!({:list, ["numpy~=1.26"]})

      # Should only call dry-run, not actual install
      assert_receive {:cmd, ^uv_path, ["pip", "install", "--dry-run" | _], _opts}
      refute_receive {:cmd, ^uv_path, ["pip", "install", "--python" | _], _opts}
    end

    test "raises PackageError on install failure", %{python_path: python_path, uv_path: uv_path} do
      Process.put(:python_packages_handler, fn
        ^uv_path, ["pip", "install", "--dry-run", "--python", ^python_path, "badpkg"], _opts ->
          {"Would install badpkg", 0}

        ^uv_path, ["pip", "install", "--python", ^python_path, "badpkg"], _opts ->
          {"error: No solution found", 2}
      end)

      error =
        assert_raise PackageError, fn ->
          PythonPackages.ensure!({:list, ["badpkg"]})
        end

      assert error.type == :install_failed
    end

    test "parses requirements files and ignores comments", %{
      python_path: python_path,
      uv_path: uv_path
    } do
      requirements_path =
        Path.join(
          System.tmp_dir!(),
          "snakepit_requirements_#{System.unique_integer([:positive])}.txt"
        )

      File.write!(requirements_path, "# comment\nnumpy~=1.26\n\nscipy>=1.11\n")

      Process.put(:python_packages_handler, fn
        ^uv_path, ["pip", "install", "--dry-run", "--python", ^python_path, _req], _opts ->
          {"Audited 1 package in 5ms", 0}
      end)

      assert :ok = PythonPackages.ensure!({:file, requirements_path})

      assert_receive {:cmd, ^uv_path,
                      ["pip", "install", "--dry-run", "--python", ^python_path, "numpy~=1.26"],
                      _opts}

      assert_receive {:cmd, ^uv_path,
                      ["pip", "install", "--dry-run", "--python", ^python_path, "scipy>=1.11"],
                      _opts}

      # No actual install since packages are satisfied
      refute_receive {:cmd, ^uv_path, ["pip", "install", "--python" | _], _opts}
    end
  end

  describe "lock_metadata/2" do
    test "returns versions for requested packages", %{python_path: python_path, uv_path: uv_path} do
      Process.put(:python_packages_handler, fn
        ^uv_path, ["pip", "freeze", "--python", ^python_path], _opts ->
          {"numpy==1.26.4\nscipy==1.11.4\n", 0}
      end)

      assert {:ok,
              %{
                "numpy" => %{version: "1.26.4", hash: nil},
                "scipy" => %{version: "1.11.4", hash: nil}
              }} = PythonPackages.lock_metadata(["numpy~=1.26", "scipy>=1.11"])
    end
  end

  describe "uv requirement" do
    test "raises PackageError when uv is not available" do
      Application.put_env(:snakepit, :python, %{managed: false, strategy: :system, uv_path: nil})
      System.put_env("PATH", Path.join(System.tmp_dir!(), "snakepit_no_uv"))

      error =
        assert_raise PackageError, fn ->
          PythonPackages.check_installed(["numpy"])
        end

      assert error.type == :uv_not_found
      assert error.message =~ "uv is required"
    end
  end

  describe "Runner.System timeout wrapper" do
    test "returns controlled error tuple when command execution crashes" do
      {output, status} =
        PythonPackages.Runner.System.cmd(
          "/definitely/missing/snakepit-command",
          [],
          timeout: 50,
          stderr_to_stdout: true
        )

      assert is_binary(output)
      assert status == 127
    end
  end

  describe "editable requirements" do
    test "treats editable installs as always needing reinstall",
         %{python_path: python_path, uv_path: uv_path} do
      # Editable requirements should not even call dry-run, they always need install
      Process.put(:python_packages_handler, fn
        ^uv_path, ["pip", "install", "--python", ^python_path, "-e", "./mypackage"], _opts ->
          {"ok", 0}
      end)

      assert {:ok, {:missing, ["-e ./mypackage"]}} =
               PythonPackages.check_installed(["-e ./mypackage"])
    end
  end
end
