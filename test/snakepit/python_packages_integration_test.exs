defmodule Snakepit.PythonPackagesIntegrationTest do
  use ExUnit.Case, async: false

  alias Snakepit.PythonPackages

  setup do
    uv = System.find_executable("uv")
    python = System.find_executable("python3") || System.find_executable("python")

    if is_nil(uv) or is_nil(python) do
      [skip: "uv or python not available"]
    else
      :ok
    end
  end

  @tag :python_integration
  test "uv installs packages into an isolated venv" do
    env_dir =
      Path.join(System.tmp_dir!(), "snakepit_uv_env_#{System.unique_integer([:positive])}")

    File.rm_rf!(env_dir)

    original_packages = Application.get_env(:snakepit, :python_packages)
    original_python = Application.get_env(:snakepit, :python)

    Application.put_env(:snakepit, :python, %{managed: false, strategy: :system})

    Application.put_env(:snakepit, :python_packages,
      installer: :uv,
      env_dir: env_dir,
      timeout: 300_000
    )

    on_exit(fn ->
      File.rm_rf!(env_dir)
      restore_env(:python_packages, original_packages)
      restore_env(:python, original_python)
    end)

    assert :ok =
             PythonPackages.ensure!({:list, ["packaging==23.2"]},
               quiet: true,
               timeout: 300_000
             )

    assert {:ok, :all_installed} = PythonPackages.check_installed(["packaging==23.2"])
  end

  defp restore_env(key, nil), do: Application.delete_env(:snakepit, key)
  defp restore_env(key, value), do: Application.put_env(:snakepit, key, value)
end
